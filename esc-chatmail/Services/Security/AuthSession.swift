import CoreData
import Foundation
import GoogleSignIn
import UIKit

@MainActor
private final class AuthenticatedGoogleUserBox {
    var user: GIDGoogleUser?
    var restoreOutcome: AuthRestoreOutcome = .retryableFailure
    var didReplaceGoogleSession = false
}

enum AuthRestoreOutcome: Equatable, Sendable {
    case authenticated
    case terminalNoSession
    case retryableFailure

    var isComplete: Bool {
        self != .retryableFailure
    }
}

struct LocalMailboxStoreInspection: Equatable, Sendable {
    let accountEmails: [String]
    let hasAccountScopedMailboxData: Bool
}

enum AccountScopedMailboxFileInspector {
    static func hasStoredFiles(fileManager: FileManager = .default) -> Bool {
        guard let appSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        let cachesDirectory = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            // An indeterminate sandbox layout must never be reported as an
            // accountless empty store.
            return true
        }
        return hasStoredFiles(
            appSupportDirectory: appSupportDirectory,
            cachesDirectory: cachesDirectory,
            fileManager: fileManager
        )
    }

    static func hasStoredFiles(
        appSupportDirectory: URL,
        cachesDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let directories = [
            appSupportDirectory.appendingPathComponent(AttachmentPaths.attachmentsFolder, isDirectory: true),
            appSupportDirectory.appendingPathComponent(AttachmentPaths.previewsFolder, isDirectory: true),
            cachesDirectory.appendingPathComponent(AttachmentPaths.legacyAttachmentCacheFolder, isDirectory: true),
            cachesDirectory.appendingPathComponent(EmailPreviewSnapshotCache.directoryName, isDirectory: true)
        ]

        for directory in directories {
            do {
                if try !fileManager.contentsOfDirectory(atPath: directory.path).isEmpty {
                    return true
                }
            } catch let error as CocoaError
                where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            } catch {
                // Permission, protection, and I/O errors do not prove absence.
                Log.warning("Could not inspect account-scoped mailbox files; requiring cleanup", category: .auth)
                return true
            }
        }
        return false
    }
}

private enum ProductionLocalMailboxStoreInspector {
    /// Every non-Account entity in the single-account store belongs to the
    /// mailbox owner. Keep this explicit so a newly added entity must make an
    /// intentional account-boundary decision.
    private static let accountScopedEntityNames = [
        "Attachment",
        "Conversation",
        "ConversationParticipant",
        "Label",
        "PendingAction",
        "OutboundSendMutationRecord",
        "Message",
        "MessageParticipant",
        "Person",
        "AbandonedSyncMessage",
        "SyncCheckpoint"
    ]

    static func inspect() async throws -> LocalMailboxStoreInspection {
        try await CoreDataStack.shared.performBackgroundTask { context in
            let accountEmails = try context.fetch(Account.fetchRequest()).map(\.email)
            var hasAccountScopedMailboxData = false

            // Normal established stores have an Account row, so avoid issuing
            // the additional existence queries on the common launch path.
            if accountEmails.isEmpty {
                for entityName in accountScopedEntityNames {
                    let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                    request.fetchLimit = 1
                    if try context.count(for: request) > 0 {
                        hasAccountScopedMailboxData = true
                        break
                    }
                }
                if !hasAccountScopedMailboxData {
                    hasAccountScopedMailboxData = try HTMLContentHandler.shared
                        .hasStoredHTMLFiles()
                }
                if !hasAccountScopedMailboxData {
                    hasAccountScopedMailboxData = AccountScopedMailboxFileInspector
                        .hasStoredFiles()
                }
            }

            return LocalMailboxStoreInspection(
                accountEmails: accountEmails,
                hasAccountScopedMailboxData: hasAccountScopedMailboxData
            )
        }
    }
}

private enum ProductionAttachmentCacheAccountTransition {
    static func closeAdmission() async {
        await AttachmentCacheActor.shared.closeAdmission()
    }

    static func reopenAdmission() async {
        await AttachmentCacheActor.shared.reopenAdmission()
    }
}

private enum ProductionParticipantCacheAccountTransition {
    static func closeAccountWorkAndClear() async {
        // ContactsResolver is itself a Person writer: direct lookups can await
        // avatar storage before saving a contact match. Drain it alongside the
        // two read/result caches before the single-account store is reset.
        await ContactsResolver.shared.closeAccountWorkAndClear()
        await PersonCache.shared.closeAccountWorkAndClear()
        await ProfilePhotoResolver.shared.closeAccountWorkAndClear()
    }

    static func reopenAccountWork() async {
        await PersonCache.shared.reopenAccountWork()
        await ContactsResolver.shared.reopenAccountWork()
        await ProfilePhotoResolver.shared.reopenAccountWork()
    }
}

/// AuthSession uses @unchecked Sendable because:
/// - All state is @MainActor isolated
/// - ObservableObject pattern requires class semantics with Sendable conformance
/// - GIDSignIn callbacks bridge into MainActor tasks before mutating session state
@MainActor
final class AuthSession: ObservableObject, @unchecked Sendable {
    private struct AccountRemovalRequest: Hashable {
        let epoch: UInt64
    }

    static let shared = AuthSession()
    static let localStoreResetRequiredKey = "auth.localStoreResetRequired.v1"
    static let credentialCleanupRequiredKey = "auth.credentialCleanupRequired.v1"
    
    @Published var isAuthenticated = false
    @Published var currentUser: GIDGoogleUser?
    @Published var userEmail: String?
    @Published var userName: String?
    @Published var accessToken: String?

    private let tokenManagerProvider: @MainActor @Sendable () -> TokenManagerProtocol
    private lazy var tokenManager: TokenManagerProtocol = tokenManagerProvider()
    private let keychainService: KeychainServiceProtocol
    private let hasPreviousGoogleSignIn: @MainActor @Sendable () -> Bool
    private let restorePreviousGoogleSignIn: @MainActor @Sendable (
        @escaping (GIDGoogleUser?, Error?) -> Void
    ) -> Void
    private let interactiveGoogleSignIn: @MainActor @Sendable (
        UIViewController,
        String?,
        @escaping @Sendable (GIDSignInResult?, Error?) -> Void
    ) -> Void
    private let signOutGoogleSession: @MainActor @Sendable () -> Void
    private let userDefaults: UserDefaults
    private let clearConversationCaches: @MainActor @Sendable () -> Void
    private let clearParticipantCaches: @Sendable () async -> Void
    private let reopenParticipantCaches: @Sendable () async -> Void
    private let cleanupDownloads: @MainActor @Sendable () async -> Void
    private let reopenDownloads: @MainActor @Sendable () async -> Void
    private let resetCoreDataStore: @Sendable () async throws -> Void
    private let inspectLocalMailboxStore: @Sendable () async throws -> LocalMailboxStoreInspection
    private let deleteAttachmentFiles: @Sendable () async throws -> Void
    private let clearAttachmentCache: @Sendable () async -> Void
    private let cleanupHTMLContent: @MainActor @Sendable () async throws -> Void
    private let reopenHTMLContent: @MainActor @Sendable () async throws -> Void
    private let revokeGoogleToken: @Sendable (String) async throws -> Void
    private let syncRunCoordinator: SyncRunCoordinator
    private let outboundTaskRegistry: OutboundTaskRegistry
    private var nextAccountRemovalEpoch: UInt64 = 0
    private var pendingAccountRemovalRequests: Set<AccountRemovalRequest> = []
    private var isAuthenticationTransitionActive = false
    private var authenticationTransitionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        tokenManagerProvider: @escaping @MainActor @Sendable () -> TokenManagerProtocol = { TokenManager.shared },
        keychainService: KeychainServiceProtocol = KeychainService.shared,
        hasPreviousGoogleSignIn: @escaping @MainActor @Sendable () -> Bool = {
            GIDSignIn.sharedInstance.hasPreviousSignIn()
        },
        restorePreviousGoogleSignIn: @escaping @MainActor @Sendable (
            @escaping (GIDGoogleUser?, Error?) -> Void
        ) -> Void = { completion in
            GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
                completion(user, error)
            }
        },
        interactiveGoogleSignIn: @escaping @MainActor @Sendable (
            UIViewController,
            String?,
            @escaping @Sendable (GIDSignInResult?, Error?) -> Void
        ) -> Void = { viewController, loginHint, completion in
            GIDSignIn.sharedInstance.signIn(
                withPresenting: viewController,
                hint: loginHint,
                additionalScopes: GoogleConfig.additionalScopes,
                completion: completion
            )
        },
        signOutGoogleSession: @escaping @MainActor @Sendable () -> Void = {
            GIDSignIn.sharedInstance.signOut()
        },
        userDefaults: UserDefaults = .standard,
        clearConversationCaches: @escaping @MainActor @Sendable () -> Void = {
            ConversationCache.shared.clearAllCaches()
        },
        clearParticipantCaches: @escaping @Sendable () async -> Void = {
            await ProductionParticipantCacheAccountTransition.closeAccountWorkAndClear()
        },
        reopenParticipantCaches: @escaping @Sendable () async -> Void = {
            await ProductionParticipantCacheAccountTransition.reopenAccountWork()
        },
        cleanupDownloads: @escaping @MainActor @Sendable () async -> Void = {
            PendingActionsManager.shared.resetQuotaRetryStateForAccountTransition()
            await AttachmentAccountWorkRegistry.shared.cancelAndAwaitAll()
            await AttachmentDownloader.shared.cancelAndAwaitAllDownloads()
            await ProductionAttachmentCacheAccountTransition.closeAdmission()
        },
        reopenDownloads: @escaping @MainActor @Sendable () async -> Void = {
            // Full cleanup removes these directories. Recreate them before
            // admitting any same-process imports or downloads for a new login.
            AttachmentPaths.setupDirectories()
            AttachmentAccountWorkRegistry.shared.reopenAdmission()
            AttachmentDownloader.shared.reopenAdmission()
            await ProductionAttachmentCacheAccountTransition.reopenAdmission()
        },
        resetCoreDataStore: @escaping @Sendable () async throws -> Void = {
            try await CoreDataStack.shared.resetStore()
        },
        inspectLocalMailboxStore: @escaping @Sendable () async throws -> LocalMailboxStoreInspection = {
            try await ProductionLocalMailboxStoreInspector.inspect()
        },
        deleteAttachmentFiles: @escaping @Sendable () async throws -> Void = {
            try AuthSession.deleteAttachmentFilesFromDisk()
        },
        clearAttachmentCache: @escaping @Sendable () async -> Void = {
            await AttachmentCacheActor.shared.clearCache(level: .aggressive)
        },
        cleanupHTMLContent: @escaping @MainActor @Sendable () async throws -> Void = {
            var firstError: Error?
            await CacheCoordinator.shared.closeAccountWorkAndAwait()
            HTMLContentHandler.shared.closeAccountWork()
            do {
                try await HTMLContentHandler.shared.deleteAllHTMLFromClosedAccount()
            } catch {
                firstError = error
            }
            await HTMLContentRecoveryService.shared.closeAccountWorkAndAwait()
            await ProcessedTextCache.shared.closeAccountWorkAndClear()
            await HTMLContentLoader.shared.closeAccountWorkAndClearCaches()
            MessageBubbleHTMLAnalysisCache.shared.closeAccountWorkAndClear()
            await EmailPreviewSnapshotRenderer.shared.closeAccountWorkAndAwait()
            do {
                try await EmailPreviewSnapshotCache.shared.closeAccountWorkAndClear()
            } catch {
                firstError = firstError ?? error
            }
            await FullEmailWebViewManager.shared.clearForAccountTransition()
            if let firstError {
                throw firstError
            }
        },
        reopenHTMLContent: @escaping @MainActor @Sendable () async throws -> Void = {
            // Reopen is also used on launch without a preceding cleanup. Retire
            // and drain any save notifications captured before this account was
            // established before advancing the component generations below.
            await CacheCoordinator.shared.closeAccountWorkAndAwait()
            try HTMLContentHandler.shared.reopenAccountWork()
            HTMLContentRecoveryService.shared.reopenAccountWork()
            ProcessedTextCache.shared.reopenAccountWork()
            await HTMLContentLoader.shared.reopenAccountWork()
            MessageBubbleHTMLAnalysisCache.shared.reopenAccountWork()
            try EmailPreviewSnapshotCache.shared.reopenAccountWork()
            EmailPreviewSnapshotRenderer.shared.reopenAccountWork()
            FullEmailWebViewManager.shared.reopenAccountWork()
            CacheCoordinator.shared.reopenAccountWork()
        },
        syncRunCoordinator: SyncRunCoordinator = .shared,
        outboundTaskRegistry: OutboundTaskRegistry? = nil,
        revokeGoogleToken: @escaping @Sendable (String) async throws -> Void = { token in
            try await AuthSession.revokeGoogleToken(token)
        }
    ) {
        self.tokenManagerProvider = tokenManagerProvider
        self.keychainService = keychainService
        self.hasPreviousGoogleSignIn = hasPreviousGoogleSignIn
        self.restorePreviousGoogleSignIn = restorePreviousGoogleSignIn
        self.interactiveGoogleSignIn = interactiveGoogleSignIn
        self.signOutGoogleSession = signOutGoogleSession
        self.userDefaults = userDefaults
        self.clearConversationCaches = clearConversationCaches
        self.clearParticipantCaches = clearParticipantCaches
        self.reopenParticipantCaches = reopenParticipantCaches
        self.cleanupDownloads = cleanupDownloads
        self.reopenDownloads = reopenDownloads
        self.resetCoreDataStore = resetCoreDataStore
        self.inspectLocalMailboxStore = inspectLocalMailboxStore
        self.deleteAttachmentFiles = deleteAttachmentFiles
        self.clearAttachmentCache = clearAttachmentCache
        self.cleanupHTMLContent = cleanupHTMLContent
        self.reopenHTMLContent = reopenHTMLContent
        self.syncRunCoordinator = syncRunCoordinator
        self.outboundTaskRegistry = outboundTaskRegistry ?? .shared
        self.revokeGoogleToken = revokeGoogleToken
        // Don't auto-restore on init
        // The app will call restorePreviousSignIn() AFTER fresh install check
    }
    
    var refreshToken: String? {
        currentUser?.refreshToken.tokenString
    }
    
    @discardableResult
    func restorePreviousSignIn() async -> AuthRestoreOutcome {
        await beginAuthenticationTransition()
        defer { endAuthenticationTransition() }

        guard !isAccountRemovalRequested else {
            return .retryableFailure
        }

        // A crash after sign-out was requested can happen before or during the
        // account drains and store/file cleanup. The durable marker wins over
        // SDK restore state and is resumed before any account can be published
        // or background-readable credentials remain available.
        if let outcome = await resumeInterruptedAccountRemovalIfNeeded() {
            return outcome
        }
        if let outcome = await resumeInterruptedCredentialCleanupIfNeeded() {
            return outcome
        }

        // A retryable launch restore can be followed by a successful interactive
        // sign-in. A later bootstrap join must not close the account work that
        // sign-in just reopened by attempting the SDK restore again.
        if isAuthenticated {
            return .authenticated
        }

        guard hasPreviousGoogleSignIn() else {
            return .terminalNoSession
        }

        let outboundTransition = outboundTaskRegistry.closeAdmission()
        await syncRunCoordinator.beginQuiescence()
        await outboundTaskRegistry.cancelAndAwaitAll()
        await clearParticipantCaches()
        await cleanupDownloads()
        let restoredUser = AuthenticatedGoogleUserBox()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            restorePreviousGoogleSignIn { [weak self] user, error in
                Task { @MainActor [weak self] in
                    defer { continuation.resume() }

                    if let error {
                        Log.warning("Failed to restore previous sign-in: \(error.localizedDescription)", category: .auth)
                    }

                    guard let self else { return }
                    guard let user else {
                        if error.map(Self.isCredentialInvalidatingRestoreError) ?? true {
                            restoredUser.restoreOutcome = self.clearFailedGoogleSession()
                                ? .terminalNoSession
                                : .retryableFailure
                        } else {
                            restoredUser.restoreOutcome = .retryableFailure
                        }
                        return
                    }
                    guard self.hasRequiredGmailScope(user) else {
                        Log.warning("Restored session missing Gmail scope; user must sign in again to grant Gmail access", category: .auth)
                        restoredUser.restoreOutcome = self.clearFailedGoogleSession()
                            ? .terminalNoSession
                            : .retryableFailure
                        return
                    }
                    guard !self.isAccountRemovalRequested else {
                        restoredUser.restoreOutcome = .retryableFailure
                        return
                    }

                    do {
                        // A previous account's store must be repaired before
                        // authenticated UI can expose any local rows.
                        try await self.prepareLocalStoreForAuthenticatedAccount(user.profile?.email)
                        guard !self.isAccountRemovalRequested else {
                            restoredUser.restoreOutcome = .retryableFailure
                            return
                        }
                        try self.persistSessionForBackgroundAccess(
                            accessToken: user.accessToken.tokenString,
                            refreshToken: user.refreshToken.tokenString,
                            expirationDate: user.accessToken.expirationDate ?? Date().addingTimeInterval(3600),
                            email: user.profile?.email
                        )
                    } catch {
                        Log.error("Failed to isolate restored account state", category: .auth, error: error)
                        _ = self.clearFailedGoogleSession()
                        restoredUser.restoreOutcome = .retryableFailure
                        return
                    }

                    // Stage the restored user only after local-store isolation
                    // and credential persistence succeed. Publication happens
                    // after account-scoped admission reopens and quiescence is
                    // released.
                    restoredUser.user = user
                }
            }
        }

        let didReopenAccountWork: Bool
        if restoredUser.user != nil {
            didReopenAccountWork = await reopenAccountWork(after: outboundTransition)
        } else {
            didReopenAccountWork = false
        }
        await syncRunCoordinator.endQuiescence()

        guard let user = restoredUser.user, didReopenAccountWork else {
            return restoredUser.restoreOutcome
        }
        publishAuthenticatedSession(user, recordsCompletedSignIn: false)
        return .authenticated
    }
    
    @MainActor
    func signIn(presenting viewController: UIViewController, loginHint: String? = nil) async throws {
        await beginAuthenticationTransition()
        defer { endAuthenticationTransition() }

        guard !isAccountRemovalRequested else {
            throw CancellationError()
        }

        let wasAuthenticated = isAuthenticated
        let outboundTransition = outboundTaskRegistry.closeAdmission()
        await syncRunCoordinator.beginQuiescence()
        await outboundTaskRegistry.cancelAndAwaitAll()
        await clearParticipantCaches()
        await cleanupDownloads()
        var releasedQuiescence = false
        let signedInUser = AuthenticatedGoogleUserBox()
        do {
            try await performSignIn(
                presenting: viewController,
                loginHint: loginHint,
                stagedUser: signedInUser
            )
            guard let user = signedInUser.user else {
                throw CancellationError()
            }
            guard await reopenAccountWork(after: outboundTransition) else {
                throw CancellationError()
            }
            await syncRunCoordinator.endQuiescence()
            releasedQuiescence = true
            publishAuthenticatedSession(user, recordsCompletedSignIn: true)
        } catch {
            if !releasedQuiescence {
                if signedInUser.didReplaceGoogleSession {
                    clearFailedGoogleSession()
                } else if wasAuthenticated {
                    await reopenPreSignInAccountWork(after: outboundTransition)
                }
                await syncRunCoordinator.endQuiescence()
            }
            throw error
        }
    }

    private func performSignIn(
        presenting viewController: UIViewController,
        loginHint: String?,
        stagedUser: AuthenticatedGoogleUserBox
    ) async throws {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: GoogleConfig.clientId)
        let normalizedLoginHint = Self.normalizedLoginHint(loginHint)

        return try await withCheckedThrowingContinuation { continuation in
            interactiveGoogleSignIn(viewController, normalizedLoginHint) { [weak self] result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: AuthError.noUser)
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self = self else {
                        continuation.resume(throwing: AuthError.noUser)
                        return
                    }
                    stagedUser.didReplaceGoogleSession = true

                    guard !self.isAccountRemovalRequested else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    guard self.hasRequiredGmailScope(result.user) else {
                        self.clearAuthState()
                        continuation.resume(throwing: AuthError.missingRequiredScopes)
                        return
                    }

                    do {
                        // Hold the account-transition lease while validating
                        // and, when necessary, replacing a previous account's
                        // persistent store. Never publish authenticated UI on
                        // top of mismatched local data.
                        try await self.prepareLocalStoreForAuthenticatedAccount(result.user.profile?.email)
                        guard !self.isAccountRemovalRequested else {
                            throw CancellationError()
                        }

                        // Save tokens and account email with background-readable access so
                        // BGTask cold starts can recover legacy sessions before Sign-In restore runs.
                        try self.persistSessionForBackgroundAccess(
                            accessToken: result.user.accessToken.tokenString,
                            refreshToken: result.user.refreshToken.tokenString,
                            expirationDate: result.user.accessToken.expirationDate ?? Date().addingTimeInterval(3600),
                            email: result.user.profile?.email
                        )

                        // The caller releases quiescence and reopens outbound
                        // admission before publishing authenticated UI.
                        stagedUser.user = result.user
                        continuation.resume()
                    } catch {
                        Log.error("Failed to complete isolated sign-in", category: .auth, error: error)
                        if let authError = error as? AuthError {
                            continuation.resume(throwing: authError)
                        } else {
                            continuation.resume(throwing: AuthError.tokenPersistenceFailed(error))
                        }
                        return
                    }
                }
            }
        }
    }
    
    @MainActor
    @discardableResult
    func signOut() async -> Bool {
        do {
            try persistLocalCleanupRequirement()
        } catch {
            Log.error("Failed to persist the sign-out cleanup prerequisite", category: .auth, error: error)
            return false
        }
        // Record intent before waiting behind another auth transition. Closing
        // outbound admission then deliberately supersedes that transition; its
        // Google callback observes the pending request before it can consume
        // the reset marker or persist a replacement session.
        let removalRequest = registerAccountRemovalRequest()
        outboundTaskRegistry.closeAdmission()
        await beginAuthenticationTransition()
        defer {
            finishAccountRemovalRequest(removalRequest)
            endAuthenticationTransition()
        }

        // Acquire the exclusive account-transition lease before publishing
        // logged-out UI. A new interactive sign-in therefore cannot start
        // until every old-account writer and this cleanup have finished.
        // The marker is durable before either drain can suspend. It records
        // logout intent without touching the store: admitted sends still own
        // their reconciliation rows until the drain below has completed. A
        // process restart observes the marker and resumes the same ordered
        // drain-before-destruction path.
        await syncRunCoordinator.beginQuiescence()
        await outboundTaskRegistry.cancelAndAwaitAll()
        await clearParticipantCaches()
        signOutGoogleSession()
        currentUser = nil
        userEmail = nil
        userName = nil
        isAuthenticated = false
        accessToken = nil
        clearAccountScopedSyncDefaults()

        // Clear the sign-in flag
        userDefaults.removeObject(forKey: "hasCompletedSignIn")
        BackgroundSyncStateManager.clearContinuationState(in: userDefaults)

        // Clear conversation cache to prevent leaking previous user's data
        clearConversationCaches()
        await AliasManager.shared.invalidate()
        await SendAsAliasManager.shared.invalidate()

        // Clear attachment downloader tracking data
        await cleanupDownloads()

        await completeDurableLocalCleanupForAccountRemoval(
            failureMessage: "Failed to clear Core Data during sign-out",
            removalRequest: removalRequest
        )
        await syncRunCoordinator.endQuiescence()
        Log.info("Sign-out cleanup completed", category: .auth)
        return true
    }

    private nonisolated static func deleteAttachmentFilesFromDisk() throws {
        let fileManager = FileManager.default

        // Get app support directory
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        // Clear Attachments directory
        let attachmentsURL = appSupportURL.appendingPathComponent("Attachments")
        if fileManager.fileExists(atPath: attachmentsURL.path) {
            try fileManager.removeItem(at: attachmentsURL)
        }

        // Clear Previews directory
        let previewsURL = appSupportURL.appendingPathComponent("Previews")
        if fileManager.fileExists(atPath: previewsURL.path) {
            try fileManager.removeItem(at: previewsURL)
        }

        // Clear any cache directories
        if let cacheURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let attachmentCacheURL = cacheURL.appendingPathComponent(AttachmentPaths.legacyAttachmentCacheFolder)
            if fileManager.fileExists(atPath: attachmentCacheURL.path) {
                try fileManager.removeItem(at: attachmentCacheURL)
            }
        }
    }

    nonisolated static func googleTokenRevocationRequest(for token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(formURLEncodedValue(token))".data(using: .utf8)
        return request
    }

    private nonisolated static func formURLEncodedValue(_ value: String) -> String {
        let hexDigits = Array("0123456789ABCDEF")
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count)

        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                encoded.append(Character(UnicodeScalar(byte)))
            default:
                encoded.append("%")
                encoded.append(hexDigits[Int(byte >> 4)])
                encoded.append(hexDigits[Int(byte & 0x0F)])
            }
        }

        return encoded
    }

    private nonisolated static func revokeGoogleToken(_ token: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let request = googleTokenRevocationRequest(for: token)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    @MainActor
    func signOutAndDisconnect() async throws {
        do {
            try persistLocalCleanupRequirement()
        } catch {
            Log.error("Failed to persist the disconnect cleanup prerequisite", category: .auth, error: error)
            throw AuthError.cleanupPrerequisitePersistenceFailed(error)
        }
        let removalRequest = registerAccountRemovalRequest()
        outboundTaskRegistry.closeAdmission()
        await beginAuthenticationTransition()
        defer {
            finishAccountRemovalRequest(removalRequest)
            endAuthenticationTransition()
        }

        // Keep admitted sends and their durable ambiguity records intact until
        // every live outbound owner has reconciled and released its reservation.
        await syncRunCoordinator.beginQuiescence()
        await outboundTaskRegistry.cancelAndAwaitAll()
        await clearParticipantCaches()

        // Capture the old credential before local SDK sign-out clears it. Use
        // a bounded token-based request below instead of GIDSignIn.disconnect:
        // the SDK callback has no finite bound and can mutate global sign-in
        // state after a new account authenticates.
        let revocationToken = refreshToken ?? accessToken
        signOutGoogleSession()

        // Clear local state immediately
        currentUser = nil
        userEmail = nil
        userName = nil
        isAuthenticated = false
        accessToken = nil
        // Clear account-scoped sync state before the remote disconnect:
        // revocation can fail, but a later sign-in must never inherit this
        // account's sync strikes or its "we synced recently" timestamps.
        clearAccountScopedSyncDefaults()

        // Clear the sign-in flag
        userDefaults.removeObject(forKey: "hasCompletedSignIn")
        BackgroundSyncStateManager.clearContinuationState(in: userDefaults)

        // Clear conversation cache to prevent leaking previous user's data
        clearConversationCaches()
        await AliasManager.shared.invalidate()
        await SendAsAliasManager.shared.invalidate()

        // Clear attachment downloader tracking data
        await cleanupDownloads()

        await completeDurableLocalCleanupForAccountRemoval(
            failureMessage: "Failed to clear Core Data during disconnect",
            removalRequest: removalRequest
        )

        let disconnectError: Error?
        do {
            guard let revocationToken, !revocationToken.isEmpty else {
                throw AuthError.noAccessToken
            }
            try await revokeGoogleToken(revocationToken)
            disconnectError = nil
        } catch {
            disconnectError = error
        }
        await syncRunCoordinator.endQuiescence()
        Log.info("Disconnect cleanup completed", category: .auth)

        if let disconnectError {
            throw disconnectError
        }
    }

    nonisolated func withFreshToken() async throws -> String {
        // Delegate to TokenManager for centralized token management
        let tokenManager = await MainActor.run { self.tokenManager }
        return try await tokenManager.getCurrentToken()
    }

    nonisolated static func normalizedLoginHint(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    /// Ensures authenticated UI can never be published over another
    /// account's surviving local store. The caller owns the account-transition
    /// lease for this entire operation.
    func prepareLocalStoreForAuthenticatedAccount(_ accountEmail: String?) async throws {
        guard let normalizedEmail = Self.normalizedLoginHint(accountEmail) else {
            throw AuthError.missingAccountEmail
        }

        let hasCleanupRequirement: Bool
        do {
            hasCleanupRequirement = try hasPersistedLocalCleanupRequirement()
        } catch {
            // A Keychain read failure cannot prove that a crash-durable reset
            // marker is absent. Refuse to publish an account until a later
            // attempt can distinguish "missing" from "temporarily unreadable."
            throw AuthError.localAccountIsolationFailed(error)
        }
        var resetRequired = hasCleanupRequirement
        if !resetRequired {
            let storeInspection: LocalMailboxStoreInspection
            do {
                storeInspection = try await inspectLocalMailboxStore()
            } catch {
                throw AuthError.localAccountIsolationFailed(error)
            }

            // This app owns one account-wide store. A matching row is not
            // sufficient if any other Account row survived an older failed
            // teardown, because conversations are not filtered by account.
            // Likewise, an absent Account row is safe only when the rest of the
            // mailbox store and canonical HTML directory are genuinely empty;
            // orphaned rows/files have no account predicate and would otherwise
            // publish under the new login.
            if storeInspection.accountEmails.isEmpty {
                resetRequired = storeInspection.hasAccountScopedMailboxData
            } else {
                resetRequired = storeInspection.accountEmails.contains {
                    $0.caseInsensitiveCompare(normalizedEmail) != .orderedSame
                }
            }
        }

        guard resetRequired else { return }

        // Persist the requirement in Keychain before touching the store. A
        // process crash or reset failure therefore cannot let a later sign-in
        // skip the remaining store/file cleanup.
        do {
            try persistLocalCleanupRequirement()
            try await performDurableLocalCleanup()
        } catch {
            throw AuthError.localAccountIsolationFailed(error)
        }

    }

    func currentOrPersistedUserEmail() -> String? {
        if let userEmail {
            return userEmail
        }

        do {
            return try keychainService.loadString(for: KeychainService.Key.googleUserEmail.rawValue)
        } catch let error as KeychainError {
            if case .itemNotFound = error {
                return nil
            }

            Log.error("Failed to load persisted user email", category: .auth, error: error)
            return nil
        } catch {
            Log.error("Failed to load persisted user email", category: .auth, error: error)
            return nil
        }
    }

    func persistSessionForBackgroundAccess(
        accessToken: String,
        refreshToken: String?,
        expirationDate: Date,
        email: String?
    ) throws {
        // This marker turns the otherwise multi-key credential write into a
        // crash-safe transaction. A launch interrupted after any partial write
        // clears the rejected credentials before considering SDK restore state.
        try persistCredentialCleanupRequirement()
        try tokenManager.saveTokens(
            access: accessToken,
            refresh: refreshToken,
            expirationDate: expirationDate
        )
        try persistUserEmailForBackgroundAccess(email)
        try clearCredentialCleanupRequirement()
    }

    func persistUserEmailForBackgroundAccess(_ email: String?) throws {
        guard let email else {
            return
        }

        try keychainService.saveString(
            email,
            for: KeychainService.Key.googleUserEmail.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )
    }

    private func hasRequiredGmailScope(_ user: GIDGoogleUser) -> Bool {
        let grantedScopes = Set(user.grantedScopes ?? [])
        return grantedScopes.contains(GoogleConfig.gmailModifyScope)
    }

    private func publishAuthenticatedSession(
        _ user: GIDGoogleUser,
        recordsCompletedSignIn: Bool
    ) {
        currentUser = user
        userEmail = user.profile?.email
        userName = user.profile?.name
        accessToken = user.accessToken.tokenString
        if recordsCompletedSignIn {
            userDefaults.set(true, forKey: "hasCompletedSignIn")
        }
        isAuthenticated = true
    }

    private func clearAuthState() {
        currentUser = nil
        userEmail = nil
        userName = nil
        isAuthenticated = false
        accessToken = nil
    }

    @discardableResult
    private func clearFailedGoogleSession() -> Bool {
        signOutGoogleSession()
        clearAuthState()
        userDefaults.removeObject(forKey: "hasCompletedSignIn")
        clearAccountScopedSyncDefaults()

        // Persist before the first delete so a crash or partial Keychain
        // failure always has a launch-time retry path. UserDefaults is a
        // compatibility fallback when Keychain itself is temporarily unable
        // to accept the marker.
        do {
            try persistCredentialCleanupRequirement()
        } catch {
            userDefaults.set(true, forKey: Self.credentialCleanupRequiredKey)
            Log.error("Failed to persist rejected-session cleanup prerequisite", category: .auth, error: error)
        }

        var firstError: Error?
        do {
            try tokenManager.clearTokens()
        } catch {
            firstError = error
            Log.error("Failed to clear tokens after rejected sign-in", category: .auth, error: error)
        }
        do {
            try keychainService.delete(for: KeychainService.Key.googleUserEmail.rawValue)
        } catch {
            firstError = firstError ?? error
            Log.error("Failed to clear persisted email after rejected sign-in", category: .auth, error: error)
        }

        guard firstError == nil else { return false }
        do {
            try clearCredentialCleanupRequirement()
            return true
        } catch {
            // The marker remains a safe false positive and will retry the
            // already-completed deletes on the next launch.
            Log.error("Failed to clear rejected-session cleanup prerequisite", category: .auth, error: error)
            return false
        }
    }

    nonisolated static func isCredentialInvalidatingRestoreError(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == kGIDSignInErrorDomain && error.code == -4)
            || (error.domain == "org.openid.appauth.oauth_token" && error.code == -10)
    }

    @discardableResult
    func reopenAccountWork(after transition: OutboundAccountTransition) async -> Bool {
        do {
            try await reopenHTMLContent()
        } catch {
            Log.error("Failed to reopen account HTML storage", category: .auth, error: error)
            // Reopening is an all-or-none account boundary. A late failure
            // must close anything the reopen sequence admitted before the
            // transition releases quiescence.
            do {
                try await cleanupHTMLContent()
            } catch {
                Log.error("Failed to roll back partial HTML reopen", category: .auth, error: error)
            }
            return false
        }
        await reopenParticipantCaches()
        await reopenDownloads()
        guard outboundTaskRegistry.reopenAdmission(after: transition) else {
            // A newer account transition superseded this one while the async
            // reopen sequence was yielding. Return every component to the
            // closed state so the stale transition cannot expose partial work
            // during the newer teardown.
            await cleanupDownloads()
            await clearParticipantCaches()
            do {
                try await cleanupHTMLContent()
            } catch {
                Log.error("Failed to roll back account work after stale reopen", category: .auth, error: error)
            }
            return false
        }
        return true
    }

    private func reopenPreSignInAccountWork(after transition: OutboundAccountTransition) async {
        await reopenParticipantCaches()
        await reopenDownloads()
        guard outboundTaskRegistry.reopenAdmission(after: transition) else {
            // A newer transition superseded this failed sign-in while its
            // Google UI was active. Roll back every stale account-work reopen.
            await cleanupDownloads()
            await clearParticipantCaches()
            return
        }
    }

    private func performDurableLocalCleanup(
        removalRequest: AccountRemovalRequest? = nil
    ) async throws {
        // Try every independent cleanup even when one fails, but retain the
        // durable marker until all credential, store, and file work succeeds.
        // This prevents a transient Keychain failure from becoming the sole
        // unretried remnant of an account transition.
        var firstError: Error?
        do {
            try performDurableCredentialCleanup()
        } catch {
            firstError = error
        }
        do {
            try await cleanupHTMLContent()
        } catch {
            firstError = firstError ?? error
        }
        // This is deliberately before the store reset. The close operation
        // invalidates admission and drains suspended Person/photo work, so an
        // old context cannot save into the replacement account's store.
        await clearParticipantCaches()
        do {
            try await resetCoreDataStore()
        } catch {
            firstError = firstError ?? error
        }
        do {
            try await deleteAttachmentFiles()
        } catch {
            firstError = firstError ?? error
        }
        await clearAttachmentCache()
        if let firstError {
            throw firstError
        }

        // These defaults are part of the same account-scoped transaction as
        // the store and files. Flush their removal before deleting the durable
        // marker so a crash can never expose a reset store with the previous
        // account's recovery windows or continuation cursor.
        clearAccountScopedSyncDefaults()
        BackgroundSyncStateManager.clearContinuationState(in: userDefaults)
        if let removalRequest {
            // An earlier removal can complete its destructive work while a
            // later removal remains queued. The shared marker belongs to both;
            // only the final pending request may consume it.
            guard pendingAccountRemovalRequests.count == 1,
                  pendingAccountRemovalRequests.contains(removalRequest) else {
                return
            }
        } else {
            // Account preparation or launch recovery does not own an in-process
            // removal request. A removal that arrived while this cleanup was
            // suspended supersedes it and retains the marker for its own turn.
            guard pendingAccountRemovalRequests.isEmpty else {
                throw CancellationError()
            }
        }

        try clearPersistedCleanupRequirement(
            key: .localStoreResetRequired,
            defaultsKey: Self.localStoreResetRequiredKey
        )
    }

    private func performDurableCredentialCleanup() throws {
        var firstError: Error?
        do {
            try tokenManager.clearTokens()
        } catch {
            firstError = error
        }
        do {
            try keychainService.delete(for: KeychainService.Key.googleUserEmail.rawValue)
        } catch {
            firstError = firstError ?? error
        }
        if let firstError {
            throw firstError
        }
        try clearCredentialCleanupRequirement()
    }

    /// Completes a sign-out that was interrupted after its durable marker was
    /// written. This runs even when Google has no previous session to restore.
    private func resumeInterruptedAccountRemovalIfNeeded() async -> AuthRestoreOutcome? {
        let cleanupRequired: Bool
        do {
            cleanupRequired = try hasPersistedLocalCleanupRequirement()
        } catch {
            Log.warning("Could not determine whether account cleanup is pending; deferring restore", category: .auth)
            return .retryableFailure
        }
        guard cleanupRequired else { return nil }

        outboundTaskRegistry.closeAdmission()
        await syncRunCoordinator.beginQuiescence()
        await outboundTaskRegistry.cancelAndAwaitAll()
        await clearParticipantCaches()

        GIDSignIn.sharedInstance.signOut()
        currentUser = nil
        userEmail = nil
        userName = nil
        isAuthenticated = false
        accessToken = nil
        clearAccountScopedSyncDefaults()

        userDefaults.removeObject(forKey: "hasCompletedSignIn")
        BackgroundSyncStateManager.clearContinuationState(in: userDefaults)
        clearConversationCaches()
        await AliasManager.shared.invalidate()
        await SendAsAliasManager.shared.invalidate()
        await cleanupDownloads()
        let cleanupSucceeded = await completeDurableLocalCleanupForAccountRemoval(
            failureMessage: "Failed to resume interrupted account cleanup"
        )
        await syncRunCoordinator.endQuiescence()
        return cleanupSucceeded ? .terminalNoSession : .retryableFailure
    }

    /// Completes a credential transaction interrupted during a rejected sign-in
    /// or restore. Unlike full account removal, the isolated local store and
    /// attachment files remain available for a later authenticated retry.
    private func resumeInterruptedCredentialCleanupIfNeeded() async -> AuthRestoreOutcome? {
        let cleanupRequired: Bool
        do {
            cleanupRequired = try hasPersistedCredentialCleanupRequirement()
        } catch {
            Log.warning("Could not determine whether credential cleanup is pending; deferring restore", category: .auth)
            return .retryableFailure
        }
        guard cleanupRequired else { return nil }

        outboundTaskRegistry.closeAdmission()
        await syncRunCoordinator.beginQuiescence()
        await outboundTaskRegistry.cancelAndAwaitAll()
        await clearParticipantCaches()

        GIDSignIn.sharedInstance.signOut()
        clearAuthState()
        clearAccountScopedSyncDefaults()
        userDefaults.removeObject(forKey: "hasCompletedSignIn")
        BackgroundSyncStateManager.clearContinuationState(in: userDefaults)
        clearConversationCaches()
        await AliasManager.shared.invalidate()
        await SendAsAliasManager.shared.invalidate()
        await cleanupDownloads()

        let cleanupSucceeded: Bool
        do {
            try performDurableCredentialCleanup()
            cleanupSucceeded = true
        } catch {
            Log.error("Failed to resume interrupted credential cleanup", category: .auth, error: error)
            cleanupSucceeded = false
        }
        await syncRunCoordinator.endQuiescence()
        return cleanupSucceeded ? .terminalNoSession : .retryableFailure
    }

    /// Keychain is the crash-durable source of truth. UserDefaults remains as
    /// a compatibility mirror so installs that entered the pre-fix failure
    /// state still fail closed and retry cleanup.
    private func hasPersistedLocalCleanupRequirement() throws -> Bool {
        try hasPersistedCleanupRequirement(
            key: .localStoreResetRequired,
            defaultsKey: Self.localStoreResetRequiredKey
        )
    }

    private func hasPersistedCredentialCleanupRequirement() throws -> Bool {
        try hasPersistedCleanupRequirement(
            key: .credentialCleanupRequired,
            defaultsKey: Self.credentialCleanupRequiredKey
        )
    }

    private func hasPersistedCleanupRequirement(
        key: KeychainService.Key,
        defaultsKey: String
    ) throws -> Bool {
        // The defaults mirror is sufficient positive evidence and avoids a
        // protected-data Keychain read during early background launches.
        if userDefaults.bool(forKey: defaultsKey) {
            return true
        }
        do {
            _ = try keychainService.load(for: key.rawValue)
            return true
        } catch KeychainError.itemNotFound {
            return false
        } catch {
            // Unlike KeychainService.exists(), preserve indeterminate OSStatus
            // failures so callers can fail closed without destroying data.
            throw error
        }
    }

    private func persistLocalCleanupRequirement() throws {
        try keychainService.save(
            Data([1]),
            for: KeychainService.Key.localStoreResetRequired.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )
        userDefaults.set(true, forKey: Self.localStoreResetRequiredKey)
    }

    private func persistCredentialCleanupRequirement() throws {
        try keychainService.save(
            Data([1]),
            for: KeychainService.Key.credentialCleanupRequired.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )
        userDefaults.set(true, forKey: Self.credentialCleanupRequiredKey)
    }

    private func clearCredentialCleanupRequirement() throws {
        try clearPersistedCleanupRequirement(
            key: .credentialCleanupRequired,
            defaultsKey: Self.credentialCleanupRequiredKey
        )
    }

    private func clearPersistedCleanupRequirement(
        key: KeychainService.Key,
        defaultsKey: String
    ) throws {
        // Persist removal of the compatibility mirror while Keychain still
        // proves cleanup is pending. If the process dies after this flush but
        // before the final delete, the Keychain marker safely retries cleanup;
        // the inverse order could resurrect a stale defaults marker after a
        // new account or credential set had already been published.
        // synchronize() is a best-effort flush only: on modern iOS it is a
        // no-op returning true, and a false return carries no information
        // worth failing a completed sign-in over — the Keychain marker stays
        // authoritative either way.
        userDefaults.removeObject(forKey: defaultsKey)
        if !userDefaults.synchronize() {
            Log.warning("Defaults mirror flush reported failure; keychain marker remains authoritative", category: .auth)
        }
        do {
            try keychainService.delete(for: key.rawValue)
        } catch {
            // Preserve the compatibility mirror when the authoritative marker
            // could not be cleared. Keychain remains the source of truth even
            // if this best-effort re-flush also fails.
            userDefaults.set(true, forKey: defaultsKey)
            _ = userDefaults.synchronize()
            throw error
        }
    }

    @discardableResult
    private func completeDurableLocalCleanupForAccountRemoval(
        failureMessage: String,
        removalRequest: AccountRemovalRequest? = nil
    ) async -> Bool {
        do {
            try await performDurableLocalCleanup(removalRequest: removalRequest)
            return true
        } catch {
            // Keep localStoreResetRequiredKey set. Interactive sign-in and
            // restore both fail closed until store and attachment cleanup succeed.
            Log.error(failureMessage, category: .coreData, error: error)
            return false
        }
    }

    /// Removes every UserDefaults-backed sync signal scoped to the account
    /// being torn down. The failure keys are pre-v3 migration state, but the
    /// two timestamps are live: `lastSuccessfulSyncTime` seeds
    /// `SyncTimeCalculator` for `.historyRecovery` and `.reconciliation`, and
    /// `lastReconciliationTime` gates `shouldSkipLabelReconciliation`. Leaving
    /// either behind lets a new account start — or skip — reconciliation as if
    /// work had already run against a store that has never synced. Clearing
    /// them only ever widens the next window, so it is also safe on the paths
    /// that deliberately retain the local store for a same-account retry.
    private func clearAccountScopedSyncDefaults() {
        userDefaults.removeObject(forKey: SyncConfig.consecutiveFailuresKey)
        userDefaults.removeObject(forKey: SyncConfig.persistentFailedIdsKey)
        userDefaults.removeObject(forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        userDefaults.removeObject(forKey: SyncConfig.lastReconciliationTimeKey)
    }

    private var isAccountRemovalRequested: Bool {
        !pendingAccountRemovalRequests.isEmpty
    }

    private func registerAccountRemovalRequest() -> AccountRemovalRequest {
        nextAccountRemovalEpoch &+= 1
        let request = AccountRemovalRequest(epoch: nextAccountRemovalEpoch)
        pendingAccountRemovalRequests.insert(request)
        return request
    }

    private func finishAccountRemovalRequest(_ request: AccountRemovalRequest) {
        pendingAccountRemovalRequests.remove(request)
    }

    /// Serializes Google SDK work and account admission transitions before
    /// either operation can advance `OutboundTaskRegistry`'s generation. In
    /// particular, a bootstrap restore retry waits for interactive sign-in to
    /// publish (or fail), then rechecks `isAuthenticated` under this lease.
    private func beginAuthenticationTransition() async {
        guard isAuthenticationTransitionActive else {
            isAuthenticationTransitionActive = true
            return
        }

        await withCheckedContinuation { continuation in
            authenticationTransitionWaiters.append(continuation)
        }
    }

    private func endAuthenticationTransition() {
        guard isAuthenticationTransitionActive else { return }
        guard !authenticationTransitionWaiters.isEmpty else {
            isAuthenticationTransitionActive = false
            return
        }

        let nextOwner = authenticationTransitionWaiters.removeFirst()
        nextOwner.resume()
    }

#if DEBUG
    /// Bounded so a regression fails the calling test's next assertion instead
    /// of hanging the whole suite on an unreachable waiter count. Kept short:
    /// tests may call this several times, and each timed-out call burns the
    /// full bound before the downstream assertions fail.
    func waitUntilAuthenticationTransitionWaiterCountForTesting(_ count: Int) async {
        let deadline = Date().addingTimeInterval(2)
        while authenticationTransitionWaiters.count < count, Date() < deadline {
            await Task.yield()
        }
    }
#endif
}

enum AuthError: LocalizedError {
    case noUser
    case noAccessToken
    case missingAccountEmail
    case localAccountIsolationFailed(Error)
    case cleanupPrerequisitePersistenceFailed(Error)
    case missingRequiredScopes
    case tokenPersistenceFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noUser:
            return "No authenticated user"
        case .noAccessToken:
            return "Failed to get access token"
        case .missingAccountEmail:
            return "The signed-in Google account did not provide an email address"
        case .localAccountIsolationFailed(let underlyingError):
            return "Could not safely isolate local mail for this account: \(underlyingError.localizedDescription)"
        case .cleanupPrerequisitePersistenceFailed(let underlyingError):
            return "Could not safely begin account cleanup: \(underlyingError.localizedDescription)"
        case .missingRequiredScopes:
            return "Google sign-in did not grant required Gmail permissions. Please try signing in again."
        case .tokenPersistenceFailed(let underlyingError):
            return "Failed to save authentication tokens: \(underlyingError.localizedDescription)"
        }
    }
}
