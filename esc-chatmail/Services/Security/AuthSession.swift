import CoreData
import Foundation
import GoogleSignIn
import Security
import UIKit

enum GoogleSignInKeychainPresence: Equatable, Sendable {
    case present
    case absent
    case indeterminate
}

private enum GoogleSignInKeychainProbe {
    /// GoogleSignIn 9 stores its GTMAppAuth session as a generic-password item
    /// with service `auth` and account `OAuth`. Query the raw item's presence
    /// instead of unarchiving it: the SDK's public `hasPreviousSignIn()` drops
    /// keychain and decoding errors into `false`, while either a present item or
    /// an OSStatus failure must remain possibly-live for background scheduling.
    static func currentPresence() -> GoogleSignInKeychainPresence {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "OAuth",
            kSecAttrService as String: "auth",
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: false
        ]

        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess:
            return .present
        case errSecItemNotFound:
            return .absent
        default:
            return .indeterminate
        }
    }
}

@MainActor
private final class AuthenticatedGoogleUserBox {
    var user: GIDGoogleUser?
    var restoreOutcome: AuthRestoreOutcome = .retryableFailure
    var didReplaceGoogleSession = false
    var didClearGoogleSession = false
}

private struct InterruptedCleanupResumeResult {
    let outcome: AuthRestoreOutcome
    let shouldSweepBackgroundTasksOnTransitionEnd: Bool
}

enum AuthRestoreOutcome: Equatable, Sendable {
    case authenticated
    case terminalNoSession
    case retryableFailure

    var isComplete: Bool {
        self != .retryableFailure
    }
}

/// Why `AuthSession.reopenAccountWork(after:)` ended.
///
/// The three refusal causes are **not** interchangeable: they differ in whether
/// retrying can ever succeed and in who else is already handling the failure, so
/// callers must branch on the cause rather than on a bare Boolean.
enum AccountWorkReopenOutcome: Hashable, CaseIterable, Sendable {
    /// Every account-scoped subsystem admits work again.
    case reopened
    /// A reopen step threw — in practice a directory recreation or other file
    /// I/O failure. Nothing is latched, so the identical transition can succeed
    /// on a later attempt.
    case transientFailure
    /// A subsystem refused because work from the closed account is still
    /// outstanding — a drain that already awaited every task it owned did not
    /// clear it (a leaked attachment operation, or an undrained outbound send
    /// reservation). That admission stays closed until the leaked work
    /// unwinds, so repeating this transition is not expected to help. Only
    /// the outbound cause proves no superseding transition exists (the
    /// registry checks transition currency before reporting its latch); the
    /// download cause cannot check, and a sign-out queued mid-reopen behind
    /// it is benign — gate-serialized after, and convergent with, the
    /// restore's credential discard.
    case latchedRefusal
    /// A newer account transition (a queued sign-out) superseded this one. That
    /// transition owns the teardown, including credential cleanup, so this one
    /// must unwind without duplicating its work.
    case supersededByAccountRemoval
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
    @Published private(set) var requiresReauthentication = false

    var canAccessMailbox: Bool {
        isAuthenticated && !requiresReauthentication
    }

    private let tokenManagerProvider: @MainActor @Sendable () -> TokenManagerProtocol
    private lazy var tokenManager: TokenManagerProtocol = tokenManagerProvider()
    private let keychainService: KeychainServiceProtocol
    private let hasPreviousGoogleSignIn: @MainActor @Sendable () -> Bool
    private let googleSignInKeychainPresence: @Sendable () -> GoogleSignInKeychainPresence
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
    private let reopenDownloads: @MainActor @Sendable () async -> Bool
    private let resetPendingActionRetryState: @MainActor @Sendable () async -> Void
    private let pendingActionAuthenticationDidRecover: @MainActor @Sendable () async -> Void
    private let cancelBackgroundTaskRequests: @MainActor @Sendable () -> Void
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
    private var isSignedOutCleanupActive = false
    private var authenticationTransitionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        tokenManagerProvider: @escaping @MainActor @Sendable () -> TokenManagerProtocol = { TokenManager.shared },
        keychainService: KeychainServiceProtocol = KeychainService.shared,
        hasPreviousGoogleSignIn: @escaping @MainActor @Sendable () -> Bool = {
            GIDSignIn.sharedInstance.hasPreviousSignIn()
        },
        googleSignInKeychainPresence: @escaping @Sendable () -> GoogleSignInKeychainPresence = {
            GoogleSignInKeychainProbe.currentPresence()
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
            await AttachmentAccountWorkRegistry.shared.cancelAndAwaitAll()
            await AttachmentDownloader.shared.cancelAndAwaitAllDownloads()
            await ProductionAttachmentCacheAccountTransition.closeAdmission()
        },
        reopenDownloads: @escaping @MainActor @Sendable () async -> Bool = {
            // Full cleanup removes these directories. Recreate them before
            // admitting any same-process imports or downloads for a new login.
            AttachmentPaths.setupDirectories()
            let didReopenAttachmentAdmission = await AuthSession.reopenAttachmentAdmission()
            await ProductionAttachmentCacheAccountTransition.reopenAdmission()
            return didReopenAttachmentAdmission
        },
        resetPendingActionRetryState: @escaping @MainActor @Sendable () async -> Void = {
            PendingActionsManager.shared.resetRetryStateForAccountTransition()
        },
        pendingActionAuthenticationDidRecover: @escaping @MainActor @Sendable () async -> Void = {
            PendingActionsManager.shared.authenticationDidRecover()
        },
        cancelBackgroundTaskRequests: @escaping @MainActor @Sendable () -> Void = {
            // A pending BGTask request re-arms itself at handler entry before
            // the unauthenticated guard runs, so any request that survives a
            // signed-out conclusion wakes the device on the sync cadence
            // forever. Sign-in needs no counterpart: the scene handler re-arms
            // on the next authenticated backgrounding.
            BackgroundTaskScheduler.shared.cancelPendingTaskRequests()
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
        self.googleSignInKeychainPresence = googleSignInKeychainPresence
        self.restorePreviousGoogleSignIn = restorePreviousGoogleSignIn
        self.interactiveGoogleSignIn = interactiveGoogleSignIn
        self.signOutGoogleSession = signOutGoogleSession
        self.userDefaults = userDefaults
        self.clearConversationCaches = clearConversationCaches
        self.clearParticipantCaches = clearParticipantCaches
        self.reopenParticipantCaches = reopenParticipantCaches
        self.cleanupDownloads = cleanupDownloads
        self.reopenDownloads = reopenDownloads
        self.resetPendingActionRetryState = resetPendingActionRetryState
        self.pendingActionAuthenticationDidRecover = pendingActionAuthenticationDidRecover
        self.cancelBackgroundTaskRequests = cancelBackgroundTaskRequests
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
        var shouldSweepBackgroundTasksOnTransitionEnd = false
        defer {
            endAuthenticationTransition(
                sweepIfDurablySignedOut: shouldSweepBackgroundTasksOnTransitionEnd
            )
        }

        guard !isAccountRemovalRequested else {
            return .retryableFailure
        }

        // A crash after sign-out was requested can happen before or during the
        // account drains and store/file cleanup. The durable marker wins over
        // SDK restore state and is resumed before any account can be published
        // or background-readable credentials remain available.
        if let result = await resumeInterruptedAccountRemovalIfNeeded() {
            shouldSweepBackgroundTasksOnTransitionEnd =
                result.shouldSweepBackgroundTasksOnTransitionEnd
            return result.outcome
        }
        if let result = await resumeInterruptedCredentialCleanupIfNeeded() {
            shouldSweepBackgroundTasksOnTransitionEnd =
                result.shouldSweepBackgroundTasksOnTransitionEnd
            return result.outcome
        }
        if let outcome = resumeDurableSignedOutStateIfNeeded() {
            return outcome
        }

        // A retryable launch restore can be followed by a successful interactive
        // sign-in. A later bootstrap join must not close the account work that
        // sign-in just reopened by attempting the SDK restore again.
        if isAuthenticated {
            return .authenticated
        }

        var shouldRejectOrphanedAppCredentials = false
        if !hasPreviousGoogleSignIn() {
            // GoogleSignIn's Boolean probe collapses keychain/unarchive errors
            // into false. An unreadable query must let bootstrap retry. A
            // present item still enters the SDK restore path so an invalid
            // archive can surface the normal terminal error. If the raw SDK
            // item is absent, app-owned credentials cannot restore on their
            // own: reject any orphaned material under the normal quiescence
            // boundary, while keeping a clean install on the fast path.
            switch googleSignInKeychainPresence() {
            case .absent:
                do {
                    guard try hasPersistedBackgroundCredentialMaterial() else {
                        shouldSweepBackgroundTasksOnTransitionEnd = true
                        return .terminalNoSession
                    }
                    shouldRejectOrphanedAppCredentials = true
                } catch {
                    Log.warning(
                        "Could not determine whether orphaned app credentials remain; deferring restore",
                        category: .auth
                    )
                    return .retryableFailure
                }
            case .indeterminate:
                return .retryableFailure
            case .present:
                break
            }
        }

        let outboundTransition = outboundTaskRegistry.closeAdmission()
        await syncRunCoordinator.beginQuiescence()
        await outboundTaskRegistry.cancelAndAwaitAll()
        await clearParticipantCaches()
        await cleanupDownloads()
        let restoredUser = AuthenticatedGoogleUserBox()
        if shouldRejectOrphanedAppCredentials {
            restoredUser.didClearGoogleSession = true
            restoredUser.restoreOutcome = clearFailedGoogleSession()
                ? .terminalNoSession
                : .retryableFailure
        } else {
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
                                restoredUser.didClearGoogleSession = true
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
                            restoredUser.didClearGoogleSession = true
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
                            restoredUser.didClearGoogleSession = true
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
        }

        var didReopenAccountWork = false
        if restoredUser.user != nil {
            await resetPendingActionRetryState()
            let reopenOutcome = await reopenAccountWork(after: outboundTransition)
            // The restore callback already persisted background-readable
            // credentials and cleared the cleanup marker, so every refusal
            // leaves them live. Only a latched refusal makes this restore their
            // sole owner; the policy explains the other two.
            switch AuthRestoreReopenPolicy.restoreDispositionAfterReopen(reopenOutcome) {
            case .publishSession:
                didReopenAccountWork = true
            case .retryKeepingCredentials:
                restoredUser.restoreOutcome = .retryableFailure
            case .discardCredentials:
                // Runs before endQuiescence(), matching signIn's catch order:
                // the clear mutates account-scoped defaults and published state.
                restoredUser.didClearGoogleSession = true
                restoredUser.restoreOutcome = discardRestoredSessionAfterFailedReopen()
            }
        }
        await syncRunCoordinator.endQuiescence()

        guard let user = restoredUser.user, didReopenAccountWork else {
            if restoredUser.didClearGoogleSession {
                // The first sweep happened when credentials were rejected.
                // Repeat it after the transition's final suspension so a task
                // delivered in between cannot leave its entry re-arm behind.
                cancelBackgroundTaskRequests()
            }
            return restoredUser.restoreOutcome
        }
        publishAuthenticatedSession(user, recordsCompletedSignIn: false)
        await pendingActionAuthenticationDidRecover()
        return .authenticated
    }
    
    @MainActor
    func signIn(presenting viewController: UIViewController, loginHint: String? = nil) async throws {
        await beginAuthenticationTransition()
        var shouldSweepBackgroundTasksOnTransitionEnd = false
        defer {
            endAuthenticationTransition(
                sweepIfDurablySignedOut: shouldSweepBackgroundTasksOnTransitionEnd
            )
        }

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
        var didResetPendingActionRetryState = false
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
            await resetPendingActionRetryState()
            didResetPendingActionRetryState = true
            // Interactive sign-in stays all-or-none for every refusal cause: its
            // catch clears the session it just replaced, so no per-cause
            // disposition is needed here.
            guard await reopenAccountWork(after: outboundTransition) == .reopened else {
                throw CancellationError()
            }
            await syncRunCoordinator.endQuiescence()
            releasedQuiescence = true
            publishAuthenticatedSession(user, recordsCompletedSignIn: true)
            await pendingActionAuthenticationDidRecover()
        } catch {
            if !releasedQuiescence {
                if signedInUser.didReplaceGoogleSession {
                    clearFailedGoogleSession()
                    if !didResetPendingActionRetryState {
                        await resetPendingActionRetryState()
                    }
                } else if wasAuthenticated {
                    await reopenPreSignInAccountWork(after: outboundTransition)
                }
                await syncRunCoordinator.endQuiescence()
            }
            if signedInUser.didReplaceGoogleSession {
                cancelBackgroundTaskRequests()
            } else {
                shouldSweepBackgroundTasksOnTransitionEnd = true
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
        // Registration makes the durable local-cleanup marker a definitive
        // sign-out verdict. Sweep before the first suspension; all later
        // scheduling gates also reject that verdict until cleanup finishes.
        cancelBackgroundTaskRequests()
        await beginAuthenticationTransition()
        defer {
            // A delivered handler can re-arm while the account drains suspend.
            // Sweep once more at the transition boundary after all such awaits.
            cancelBackgroundTaskRequests()
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
        await resetPendingActionRetryState()
        await clearParticipantCaches()
        signOutGoogleSession()
        currentUser = nil
        userEmail = nil
        userName = nil
        isAuthenticated = false
        requiresReauthentication = false
        accessToken = nil
        clearAccountScopedSyncDefaults()

        // Clear the sign-in flag
        userDefaults.removeObject(forKey: "hasCompletedSignIn")
        BackgroundSyncStateManager.clearContinuationState(in: userDefaults)
        // Disarm pending background sync wakes. This runs after
        // isAuthenticated is false and inside quiescence, so neither the
        // scene handler nor an in-flight background run can re-arm a request
        // behind this sweep: the scene arm re-checks its auth gate in the
        // same MainActor slice as its submits, so it either submitted before
        // this sweep (and is swept here) or observes the dropped flag and
        // arms nothing.
        cancelBackgroundTaskRequests()

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

    /// Reopens both attachment admission owners and reports whether *both*
    /// accepted.
    ///
    /// Each closure is evaluated exactly once, deliberately without `&&`:
    /// short-circuiting on the first refusal would leave the second owner
    /// latched closed with no matching rollback, and a later transition could
    /// then never tell which half is holding attachments shut.
    static func reopenAttachmentAdmission(
        reopenRegistry: @MainActor @Sendable () async -> Bool = {
            AttachmentAccountWorkRegistry.shared.reopenAdmission()
        },
        reopenDownloader: @MainActor @Sendable () async -> Bool = {
            AttachmentDownloader.shared.reopenAdmission()
        }
    ) async -> Bool {
        let registryDidReopen = await reopenRegistry()
        let downloaderDidReopen = await reopenDownloader()
        return registryDidReopen && downloaderDidReopen
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
        cancelBackgroundTaskRequests()
        await beginAuthenticationTransition()
        defer {
            cancelBackgroundTaskRequests()
            finishAccountRemovalRequest(removalRequest)
            endAuthenticationTransition()
        }

        // Keep admitted sends and their durable ambiguity records intact until
        // every live outbound owner has reconciled and released its reservation.
        await syncRunCoordinator.beginQuiescence()
        await outboundTaskRegistry.cancelAndAwaitAll()
        await resetPendingActionRetryState()
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
        requiresReauthentication = false
        accessToken = nil
        // Clear account-scoped sync state before the remote disconnect:
        // revocation can fail, but a later sign-in must never inherit this
        // account's sync strikes or its "we synced recently" timestamps.
        clearAccountScopedSyncDefaults()

        // Clear the sign-in flag
        userDefaults.removeObject(forKey: "hasCompletedSignIn")
        BackgroundSyncStateManager.clearContinuationState(in: userDefaults)
        cancelBackgroundTaskRequests()

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

    /// App-owned credentials support background access only after the Google
    /// SDK session has restored. Presence therefore identifies remnants to
    /// clean, while any non-item-not-found error remains indeterminate.
    private func hasPersistedBackgroundCredentialMaterial() throws -> Bool {
        for key in [
            KeychainService.Key.googleAccessToken,
            .googleRefreshToken,
            .googleUserEmail
        ] {
            do {
                _ = try keychainService.load(for: key.rawValue)
                return true
            } catch KeychainError.itemNotFound {
                continue
            }
        }
        return false
    }

    /// Whether this device has definitively concluded signed out.
    ///
    /// Not equivalent to `currentOrPersistedUserEmail() == nil`, which also
    /// returns nil when the keychain read *fails* and treats an orphaned email
    /// as live without consulting SDK evidence. Positive account-removal intent
    /// is definitive because it is persisted before the in-process request is
    /// registered. Every live/transitioning signal and every unreadable
    /// credential source otherwise fails safe as possibly authenticated.
    ///
    /// The raw SDK-keychain check protects legacy upgrades. GoogleSignIn's
    /// Boolean `hasPreviousSignIn()` suppresses keychain/unarchive errors. A
    /// readable app credential may be an orphan but cannot restore without the
    /// SDK session, while any unreadable app or SDK source remains possibly live.
    func isDurablySignedOut() -> Bool {
        // Registration follows the successful durable marker write without a
        // MainActor suspension, so this is positive sign-out evidence even
        // before the async account drains have cleared published state.
        if isAccountRemovalRequested || isSignedOutCleanupActive {
            return true
        }

        guard !isAuthenticated, currentUser == nil, userEmail == nil else {
            return false
        }

        // Interactive sign-in and restore temporarily have no published or
        // persisted app credentials. Do not infer absence while either is
        // still capable of publishing a session.
        guard !isAuthenticationTransitionActive else {
            return false
        }

        if userDefaults.bool(forKey: Self.localStoreResetRequiredKey)
            || userDefaults.bool(forKey: Self.credentialCleanupRequiredKey) {
            return true
        }

        do {
            if try hasPersistedDurableSignedOutState()
                || hasPersistedLocalCleanupRequirement()
                || hasPersistedCredentialCleanupRequirement() {
                return true
            }
        } catch {
            Log.warning(
                "Treating unreadable account-removal intent as a possibly-live session",
                category: .auth
            )
            return false
        }

        do {
            _ = try hasPersistedBackgroundCredentialMaterial()
        } catch {
            Log.warning(
                "Treating unreadable persisted app credentials as a possibly-live session",
                category: .auth
            )
            return false
        }

        guard !hasPreviousGoogleSignIn() else {
            return false
        }

        switch googleSignInKeychainPresence() {
        case .absent:
            return true
        case .present, .indeterminate:
            return false
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
        // The app-owned sign-out verdict outlives GoogleSignIn keychain errors.
        // Consume it only after the replacement session is fully persisted;
        // if deletion fails, the credential transaction remains marked and the
        // caller rejects this partial sign-in rather than silently disabling BG sync.
        try clearDurableSignedOutState()
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
        requiresReauthentication = false
        isAuthenticated = true
    }

    func requireReauthentication() {
        guard isAuthenticated else { return }
        requiresReauthentication = true
    }

    private func clearAuthState() {
        currentUser = nil
        userEmail = nil
        userName = nil
        requiresReauthentication = false
        isAuthenticated = false
        accessToken = nil
    }

    /// Discards a restored session whose account-scoped reopen latched closed.
    ///
    /// A restore stages live credentials before the reopen sequence runs, so a
    /// refused reopen leaves background-readable tokens for an account that was
    /// never published. Call this **only** for the disposition
    /// `AuthRestoreReopenPolicy` maps to `.discardCredentials`: the other
    /// refusal causes are either retryable with exactly these credentials or
    /// already owned by a superseding sign-out. The caller runs this while
    /// quiescence is still held and never publishes a session afterwards, so
    /// pending-action recovery must not be signalled.
    func discardRestoredSessionAfterFailedReopen() -> AuthRestoreOutcome {
        Log.error(
            "Failed to reopen account work for a restored session; discarding staged credentials",
            category: .auth
        )
        return clearFailedGoogleSession() ? .terminalNoSession : .retryableFailure
    }

    @discardableResult
    private func clearFailedGoogleSession() -> Bool {
        // Persist both the cleanup transaction and the long-lived signed-out
        // verdict before mutating the SDK session. If the process dies after
        // `signOutGoogleSession()`, launch recovery can still finish the reject.
        var firstError: Error?
        do {
            try persistCredentialCleanupRequirement()
        } catch {
            firstError = error
            userDefaults.set(true, forKey: Self.credentialCleanupRequiredKey)
            Log.error("Failed to persist rejected-session cleanup prerequisite", category: .auth, error: error)
        }
        do {
            try persistDurableSignedOutState()
        } catch {
            firstError = firstError ?? error
            Log.error("Failed to persist durable signed-out state", category: .auth, error: error)
        }

        signOutGoogleSession()
        clearAuthState()
        userDefaults.removeObject(forKey: "hasCompletedSignIn")
        clearAccountScopedSyncDefaults()
        // Every caller concludes signed out with credentials cleared, so any
        // pending BGTask request is the same perpetual no-op wake sign-out
        // disarms. All call sites hold quiescence, and clearAuthState() above
        // dropped the flag the scene arm re-checks in the same MainActor
        // slice as its submits — an in-flight arm either already submitted
        // (swept here) or arms nothing.
        cancelBackgroundTaskRequests()

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

    /// Reopens every account-scoped subsystem, all-or-none.
    ///
    /// Anything but `.reopened` means no authenticated session may be
    /// published. The distinct refusal cases exist because callers must treat
    /// them differently — see `AuthRestoreReopenPolicy`.
    func reopenAccountWork(after transition: OutboundAccountTransition) async -> AccountWorkReopenOutcome {
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
            return .transientFailure
        }
        await reopenParticipantCaches()
        guard await reopenDownloads() else {
            // A leaked download or file operation kept attachment admission
            // closed. Reopening is all-or-none, so roll back in the same order
            // a superseded transition does rather than publishing a session
            // whose attachment work can never start.
            Log.error("Failed to reopen account download admission", category: .auth)
            await rollBackReopenedAccountWork(after: "refused download reopen")
            return .latchedRefusal
        }
        switch outboundTaskRegistry.reopenAdmission(after: transition) {
        case .reopened:
            return .reopened
        case .supersededByNewerTransition:
            // A newer account transition superseded this one while the async
            // reopen sequence was yielding. Return every component to the
            // closed state so the stale transition cannot expose partial work
            // during the newer teardown.
            await rollBackReopenedAccountWork(after: "stale reopen")
            return .supersededByAccountRemoval
        case .undrainedSends:
            // The transition is still current, but a send reservation survived
            // the cancelAndAwaitAll() drain. No queued sign-out exists to own
            // credential cleanup, so reporting supersession here would be
            // false; this is the same latched shape as a refused download
            // reopen and takes the same all-or-none rollback.
            Log.error("Failed to reopen outbound admission: send reservation never drained", category: .auth)
            await rollBackReopenedAccountWork(after: "refused outbound reopen")
            return .latchedRefusal
        }
    }

    /// Rolls back every subsystem `reopenAccountWork(after:)` already
    /// admitted, in the reverse of reopen order, so a refused transition
    /// cannot expose partial work. Serves only that function's three
    /// full-rollback refusal legs; the `.transientFailure` leg (HTML only)
    /// and `reopenPreSignInAccountWork`'s deliberately partial rollback keep
    /// their own shapes.
    private func rollBackReopenedAccountWork(after failureContext: String) async {
        await cleanupDownloads()
        await clearParticipantCaches()
        do {
            try await cleanupHTMLContent()
        } catch {
            Log.error("Failed to roll back account work after \(failureContext)", category: .auth, error: error)
        }
    }

    private func reopenPreSignInAccountWork(after transition: OutboundAccountTransition) async {
        await reopenParticipantCaches()
        if await reopenDownloads() == false {
            // Deliberately NOT all-or-none, unlike reopenAccountWork(after:).
            // This path restores the account that is still published — a failed
            // sign-in never replaced it — and the caller has no way to unpublish
            // it. Refusing outbound admission here would leave a live session
            // permanently unable to send; a latched attachment registry only
            // costs downloads and imports until relaunch. Degrade, don't widen.
            Log.error("Failed to reopen download admission for the pre-sign-in account", category: .auth)
        }
        switch outboundTaskRegistry.reopenAdmission(after: transition) {
        case .reopened:
            break
        case .supersededByNewerTransition:
            // A newer transition superseded this failed sign-in while its
            // Google UI was active. Roll back every stale account-work reopen.
            await cleanupDownloads()
            await clearParticipantCaches()
        case .undrainedSends:
            // Same degrade-don't-widen shape as the refused download reopen
            // above: no newer transition exists whose teardown a rollback
            // would protect, so closing downloads and caches would only strip
            // the still-published session of the capabilities it retains.
            // Sending alone is lost — draining never reopens admission, so
            // the latch holds until the next auth transition's
            // drain-then-reopen cycle or a relaunch, not until the leaked
            // reservation unwinds.
            Log.error("Failed to reopen outbound admission for the pre-sign-in account", category: .auth)
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

        // Hand the transaction from "cleanup still required" to the durable
        // signed-out verdict before consuming the former marker. There is no
        // crash point at which both are absent, and a failed second write keeps
        // launch recovery armed instead of reporting that sign-out never began.
        try persistDurableSignedOutState()
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

    /// Rejects an SDK session that survived a previously completed sign-out.
    /// GoogleSignIn's `signOut()` ignores keychain deletion errors, so the
    /// app-owned verdict must win before automatic SDK restore is attempted.
    private func resumeDurableSignedOutStateIfNeeded() -> AuthRestoreOutcome? {
        let isDurablySignedOut: Bool
        do {
            isDurablySignedOut = try hasPersistedDurableSignedOutState()
        } catch {
            Log.warning("Could not read durable signed-out state; deferring restore", category: .auth)
            return .retryableFailure
        }
        guard isDurablySignedOut else { return nil }

        signOutGoogleSession()
        clearAuthState()
        userDefaults.removeObject(forKey: "hasCompletedSignIn")
        clearAccountScopedSyncDefaults()
        BackgroundSyncStateManager.clearContinuationState(in: userDefaults)
        cancelBackgroundTaskRequests()

        do {
            try performDurableCredentialCleanup()
            return .terminalNoSession
        } catch {
            Log.error("Failed to clear credentials preserved after sign-out", category: .auth, error: error)
            return .retryableFailure
        }
    }

    /// Completes a sign-out that was interrupted after its durable marker was
    /// written. This runs even when Google has no previous session to restore.
    private func resumeInterruptedAccountRemovalIfNeeded() async -> InterruptedCleanupResumeResult? {
        let cleanupRequired: Bool
        do {
            cleanupRequired = try hasPersistedLocalCleanupRequirement()
        } catch {
            Log.warning("Could not determine whether account cleanup is pending; deferring restore", category: .auth)
            return InterruptedCleanupResumeResult(
                outcome: .retryableFailure,
                shouldSweepBackgroundTasksOnTransitionEnd: false
            )
        }
        guard cleanupRequired else { return nil }
        do {
            // Migrate interrupted removals created before the durable marker
            // existed before consuming their older cleanup prerequisite.
            try persistDurableSignedOutState()
        } catch {
            Log.warning("Could not persist durable signed-out state; deferring cleanup", category: .auth)
            return InterruptedCleanupResumeResult(
                outcome: .retryableFailure,
                shouldSweepBackgroundTasksOnTransitionEnd: true
            )
        }
        isSignedOutCleanupActive = true
        defer {
            // The early sweep below can race a handler delivered while cleanup
            // suspends. Keep the positive verdict live through one final sweep.
            cancelBackgroundTaskRequests()
            isSignedOutCleanupActive = false
        }

        outboundTaskRegistry.closeAdmission()
        cancelBackgroundTaskRequests()
        await syncRunCoordinator.beginQuiescence()
        await outboundTaskRegistry.cancelAndAwaitAll()
        await resetPendingActionRetryState()
        await clearParticipantCaches()

        GIDSignIn.sharedInstance.signOut()
        currentUser = nil
        userEmail = nil
        userName = nil
        isAuthenticated = false
        requiresReauthentication = false
        accessToken = nil
        clearAccountScopedSyncDefaults()

        userDefaults.removeObject(forKey: "hasCompletedSignIn")
        BackgroundSyncStateManager.clearContinuationState(in: userDefaults)
        cancelBackgroundTaskRequests()
        clearConversationCaches()
        await AliasManager.shared.invalidate()
        await SendAsAliasManager.shared.invalidate()
        await cleanupDownloads()
        let cleanupSucceeded = await completeDurableLocalCleanupForAccountRemoval(
            failureMessage: "Failed to resume interrupted account cleanup"
        )
        await syncRunCoordinator.endQuiescence()
        return InterruptedCleanupResumeResult(
            outcome: cleanupSucceeded ? .terminalNoSession : .retryableFailure,
            shouldSweepBackgroundTasksOnTransitionEnd: false
        )
    }

    /// Completes a credential transaction interrupted during a rejected sign-in
    /// or restore. Unlike full account removal, the isolated local store and
    /// attachment files remain available for a later authenticated retry.
    private func resumeInterruptedCredentialCleanupIfNeeded() async -> InterruptedCleanupResumeResult? {
        let cleanupRequired: Bool
        do {
            cleanupRequired = try hasPersistedCredentialCleanupRequirement()
        } catch {
            Log.warning("Could not determine whether credential cleanup is pending; deferring restore", category: .auth)
            return InterruptedCleanupResumeResult(
                outcome: .retryableFailure,
                shouldSweepBackgroundTasksOnTransitionEnd: false
            )
        }
        guard cleanupRequired else { return nil }
        do {
            try persistDurableSignedOutState()
        } catch {
            Log.warning("Could not persist durable signed-out state; deferring cleanup", category: .auth)
            return InterruptedCleanupResumeResult(
                outcome: .retryableFailure,
                shouldSweepBackgroundTasksOnTransitionEnd: true
            )
        }
        isSignedOutCleanupActive = true
        defer {
            cancelBackgroundTaskRequests()
            isSignedOutCleanupActive = false
        }

        outboundTaskRegistry.closeAdmission()
        cancelBackgroundTaskRequests()
        await syncRunCoordinator.beginQuiescence()
        await outboundTaskRegistry.cancelAndAwaitAll()
        await resetPendingActionRetryState()
        await clearParticipantCaches()

        GIDSignIn.sharedInstance.signOut()
        clearAuthState()
        clearAccountScopedSyncDefaults()
        userDefaults.removeObject(forKey: "hasCompletedSignIn")
        BackgroundSyncStateManager.clearContinuationState(in: userDefaults)
        cancelBackgroundTaskRequests()
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
        return InterruptedCleanupResumeResult(
            outcome: cleanupSucceeded ? .terminalNoSession : .retryableFailure,
            shouldSweepBackgroundTasksOnTransitionEnd: false
        )
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

    private func hasPersistedDurableSignedOutState() throws -> Bool {
        do {
            _ = try keychainService.load(for: KeychainService.Key.durableSignedOut.rawValue)
            return true
        } catch KeychainError.itemNotFound {
            return false
        } catch {
            throw error
        }
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

    private func persistDurableSignedOutState() throws {
        try keychainService.save(
            Data([1]),
            for: KeychainService.Key.durableSignedOut.rawValue,
            withAccess: .afterFirstUnlockThisDeviceOnly
        )
    }

    private func clearDurableSignedOutState() throws {
        try keychainService.delete(for: KeychainService.Key.durableSignedOut.rawValue)
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

    private func endAuthenticationTransition(sweepIfDurablySignedOut: Bool = false) {
        guard isAuthenticationTransitionActive else { return }
        guard !authenticationTransitionWaiters.isEmpty else {
            isAuthenticationTransitionActive = false
            // Background-task handlers re-arm before their worker can ask for
            // the durable verdict. While a transition owns this lease that
            // verdict deliberately fails safe, so a cancelled sign-in (or a
            // queued restore's terminal fast path) must sweep once the final
            // owner has conclusively returned to signed-out state.
            if sweepIfDurablySignedOut, isDurablySignedOut() {
                cancelBackgroundTaskRequests()
            }
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
