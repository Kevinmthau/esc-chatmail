import Foundation
import GoogleSignIn
import UIKit

/// AuthSession uses @unchecked Sendable because:
/// - All state is @MainActor isolated
/// - ObservableObject pattern requires class semantics with Sendable conformance
/// - GIDSignIn callbacks are properly dispatched to MainActor via DispatchQueue.main.async
@MainActor
final class AuthSession: ObservableObject, @unchecked Sendable {
    static let shared = AuthSession()
    
    @Published var isAuthenticated = false
    @Published var currentUser: GIDGoogleUser?
    @Published var userEmail: String?
    @Published var userName: String?
    @Published var accessToken: String?

    private let tokenManagerProvider: @MainActor @Sendable () -> TokenManagerProtocol
    private lazy var tokenManager: TokenManagerProtocol = tokenManagerProvider()
    private let keychainService: KeychainServiceProtocol
    private let userDefaults: UserDefaults
    private let clearConversationCaches: @MainActor @Sendable () -> Void
    private let cleanupDownloads: @MainActor @Sendable () -> Void
    private let resetCoreDataStore: @Sendable () async throws -> Void
    private let clearAttachmentCache: @Sendable () async -> Void

    init(
        tokenManagerProvider: @escaping @MainActor @Sendable () -> TokenManagerProtocol = { TokenManager.shared },
        keychainService: KeychainServiceProtocol = KeychainService.shared,
        userDefaults: UserDefaults = .standard,
        clearConversationCaches: @escaping @MainActor @Sendable () -> Void = {
            ConversationCache.shared.clearAllCaches()
        },
        cleanupDownloads: @escaping @MainActor @Sendable () -> Void = {
            AttachmentDownloader.shared.cleanupAll()
        },
        resetCoreDataStore: @escaping @Sendable () async throws -> Void = {
            try await CoreDataStack.shared.resetStore()
        },
        clearAttachmentCache: @escaping @Sendable () async -> Void = {
            await AttachmentCacheActor.shared.clearCache(level: .aggressive)
        }
    ) {
        self.tokenManagerProvider = tokenManagerProvider
        self.keychainService = keychainService
        self.userDefaults = userDefaults
        self.clearConversationCaches = clearConversationCaches
        self.cleanupDownloads = cleanupDownloads
        self.resetCoreDataStore = resetCoreDataStore
        self.clearAttachmentCache = clearAttachmentCache
        // Don't auto-restore on init
        // The app will call restorePreviousSignIn() AFTER fresh install check
    }
    
    var refreshToken: String? {
        currentUser?.refreshToken.tokenString
    }
    
    func restorePreviousSignIn() async {
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else {
            return
        }

        await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, error in
                DispatchQueue.main.async {
                    if let error {
                        Log.warning("Failed to restore previous sign-in: \(error.localizedDescription)", category: .auth)
                    }
                    if let user = user {
                        guard self?.hasRequiredGmailScope(user) == true else {
                            Log.warning("Restored session missing Gmail scope; user must sign in again to grant Gmail access", category: .auth)
                            self?.clearAuthState()
                            continuation.resume()
                            return
                        }
                        self?.currentUser = user
                        self?.userEmail = user.profile?.email
                        self?.userName = user.profile?.name
                        self?.isAuthenticated = true
                        self?.accessToken = user.accessToken.tokenString
                        do {
                            try self?.persistUserEmailForBackgroundAccess(user.profile?.email)
                        } catch {
                            Log.error("Failed to migrate persisted user email for background access", category: .auth, error: error)
                        }
                    }
                    continuation.resume()
                }
            }
        }
    }
    
    @MainActor
    func signIn(presenting viewController: UIViewController, loginHint: String? = nil) async throws {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: GoogleConfig.clientId)
        let normalizedLoginHint = Self.normalizedLoginHint(loginHint)

        return try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(
                withPresenting: viewController,
                hint: normalizedLoginHint,
                additionalScopes: GoogleConfig.additionalScopes
            ) { [weak self] result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: AuthError.noUser)
                    return
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else {
                        continuation.resume(throwing: AuthError.noUser)
                        return
                    }

                    guard self.hasRequiredGmailScope(result.user) else {
                        self.clearAuthState()
                        continuation.resume(throwing: AuthError.missingRequiredScopes)
                        return
                    }

                    self.currentUser = result.user
                    self.userEmail = result.user.profile?.email
                    self.userName = result.user.profile?.name
                    self.accessToken = result.user.accessToken.tokenString

                    // Save tokens securely using TokenManager
                    do {
                        try self.tokenManager.saveTokens(
                            access: result.user.accessToken.tokenString,
                            refresh: result.user.refreshToken.tokenString,
                            expirationDate: result.user.accessToken.expirationDate ?? Date().addingTimeInterval(3600)
                        )

                        // Save user email with background-readable access so BGTask cold starts
                        // can recover the account scope before GoogleSignIn restoration runs.
                        try self.persistUserEmailForBackgroundAccess(result.user.profile?.email)

                        // Only mark as authenticated after tokens are successfully saved
                        self.isAuthenticated = true

                        // Mark that user has successfully signed in
                        self.userDefaults.set(true, forKey: "hasCompletedSignIn")

                        // Success - resume inside do block after all state is set
                        continuation.resume()
                    } catch {
                        Log.error("Failed to save tokens - clearing auth state", category: .auth, error: error)
                        // Clear auth state since tokens weren't persisted
                        self.clearAuthState()
                        continuation.resume(throwing: AuthError.tokenPersistenceFailed(error))
                    }
                }
            }
        }
    }
    
    @MainActor
    func signOut() async {
        GIDSignIn.sharedInstance.signOut()
        currentUser = nil
        userEmail = nil
        userName = nil
        isAuthenticated = false
        accessToken = nil

        // Clear tokens from secure storage
        do {
            try tokenManager.clearTokens()
            try keychainService.delete(for: KeychainService.Key.googleUserEmail.rawValue)
        } catch {
            Log.error("Failed to clear tokens", category: .auth, error: error)
        }

        // Clear the sign-in flag
        userDefaults.removeObject(forKey: "hasCompletedSignIn")
        BackgroundSyncStateManager.clearContinuationState(in: userDefaults)

        // Clear conversation cache to prevent leaking previous user's data
        clearConversationCaches()

        // Clear attachment downloader tracking data
        cleanupDownloads()

        // Clear attachment files from disk
        clearAttachmentFiles()

        // Await async cleanup tasks to ensure completion before allowing new sign-in
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await self.resetCoreDataStore()
                } catch {
                    Log.error("Failed to clear Core Data during sign-out", category: .coreData, error: error)
                }
            }

            group.addTask {
                await self.clearAttachmentCache()
            }
        }
        Log.info("Sign-out cleanup completed", category: .auth)
    }

    private func clearAttachmentFiles() {
        let fileManager = FileManager.default

        // Get app support directory
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            Log.warning("Could not find application support directory for cleanup", category: .auth)
            return
        }

        // Clear Attachments directory
        let attachmentsURL = appSupportURL.appendingPathComponent("Attachments")
        if fileManager.fileExists(atPath: attachmentsURL.path) {
            do {
                try fileManager.removeItem(at: attachmentsURL)
            } catch {
                Log.error("Failed to remove Attachments directory during sign-out - previous user's files may persist", category: .auth, error: error)
            }
        }

        // Clear Previews directory
        let previewsURL = appSupportURL.appendingPathComponent("Previews")
        if fileManager.fileExists(atPath: previewsURL.path) {
            do {
                try fileManager.removeItem(at: previewsURL)
            } catch {
                Log.error("Failed to remove Previews directory during sign-out - previous user's files may persist", category: .auth, error: error)
            }
        }

        // Clear any cache directories
        if let cacheURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let attachmentCacheURL = cacheURL.appendingPathComponent("AttachmentCache")
            if fileManager.fileExists(atPath: attachmentCacheURL.path) {
                do {
                    try fileManager.removeItem(at: attachmentCacheURL)
                } catch {
                    Log.error("Failed to remove AttachmentCache directory during sign-out - previous user's files may persist", category: .auth, error: error)
                }
            }
        }
    }

    @MainActor
    func signOutAndDisconnect() async throws {
        // First sign out
        GIDSignIn.sharedInstance.signOut()

        // Clear local state immediately
        currentUser = nil
        userEmail = nil
        userName = nil
        isAuthenticated = false
        accessToken = nil

        // Then disconnect to revoke tokens (wrap callback in continuation)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            GIDSignIn.sharedInstance.disconnect { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        // Clear tokens from secure storage
        do {
            try tokenManager.clearTokens()
            try keychainService.delete(for: KeychainService.Key.googleUserEmail.rawValue)
        } catch {
            Log.error("Failed to clear tokens", category: .auth, error: error)
        }

        // Clear the sign-in flag
        userDefaults.removeObject(forKey: "hasCompletedSignIn")
        BackgroundSyncStateManager.clearContinuationState(in: userDefaults)

        // Clear conversation cache to prevent leaking previous user's data
        clearConversationCaches()

        // Clear attachment downloader tracking data
        cleanupDownloads()

        // Clear attachment files from disk
        clearAttachmentFiles()

        // Await async cleanup tasks to ensure completion before allowing new sign-in
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await self.resetCoreDataStore()
                } catch {
                    Log.error("Failed to clear Core Data during disconnect", category: .coreData, error: error)
                }
            }

            group.addTask {
                await self.clearAttachmentCache()
            }
        }
        Log.info("Disconnect cleanup completed", category: .auth)
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

    private func clearAuthState() {
        currentUser = nil
        userEmail = nil
        userName = nil
        isAuthenticated = false
        accessToken = nil
    }
}

enum AuthError: LocalizedError {
    case noUser
    case noAccessToken
    case missingRequiredScopes
    case tokenPersistenceFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noUser:
            return "No authenticated user"
        case .noAccessToken:
            return "Failed to get access token"
        case .missingRequiredScopes:
            return "Google sign-in did not grant required Gmail permissions. Please try signing in again."
        case .tokenPersistenceFailed(let underlyingError):
            return "Failed to save authentication tokens: \(underlyingError.localizedDescription)"
        }
    }
}
