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
    
    private init() {
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
                    if let user = user {
                        self?.currentUser = user
                        self?.userEmail = user.profile?.email
                        self?.userName = user.profile?.name
                        self?.isAuthenticated = true
                        self?.accessToken = user.accessToken.tokenString
                    }
                    continuation.resume()
                }
            }
        }
    }
    
    @MainActor
    func signIn(presenting viewController: UIViewController) async throws {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: GoogleConfig.clientId)

        return try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(withPresenting: viewController) { [weak self] result, error in
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

                    self.currentUser = result.user
                    self.userEmail = result.user.profile?.email
                    self.userName = result.user.profile?.name
                    self.accessToken = result.user.accessToken.tokenString

                    // Save tokens securely using TokenManager
                    do {
                        try TokenManager.shared.saveTokens(
                            access: result.user.accessToken.tokenString,
                            refresh: result.user.refreshToken.tokenString,
                            expirationDate: result.user.accessToken.expirationDate ?? Date().addingTimeInterval(3600)
                        )

                        // Save user email to keychain
                        if let email = result.user.profile?.email {
                            try KeychainService.shared.saveString(email, for: .googleUserEmail, withAccess: .whenUnlockedThisDeviceOnly)
                        }

                        // Only mark as authenticated after tokens are successfully saved
                        self.isAuthenticated = true

                        // Mark that user has successfully signed in
                        UserDefaults.standard.set(true, forKey: "hasCompletedSignIn")

                        // Success - resume inside do block after all state is set
                        continuation.resume()
                    } catch {
                        Log.error("Failed to save tokens - clearing auth state", category: .auth, error: error)
                        // Clear auth state since tokens weren't persisted
                        self.currentUser = nil
                        self.userEmail = nil
                        self.userName = nil
                        self.accessToken = nil
                        self.isAuthenticated = false
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
            try TokenManager.shared.clearTokens()
            try KeychainService.shared.delete(for: .googleUserEmail)
        } catch {
            Log.error("Failed to clear tokens", category: .auth, error: error)
        }

        // Clear the sign-in flag
        UserDefaults.standard.removeObject(forKey: "hasCompletedSignIn")

        // Clear conversation cache to prevent leaking previous user's data
        ConversationCache.shared.clearAllCaches()

        // Clear attachment downloader tracking data
        AttachmentDownloader.shared.cleanupAll()

        // Clear attachment files from disk
        clearAttachmentFiles()

        // Await async cleanup tasks to ensure completion before allowing new sign-in
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await CoreDataStack.shared.resetStore()
                } catch {
                    Log.error("Failed to clear Core Data during sign-out", category: .coreData, error: error)
                }
            }

            group.addTask {
                await AttachmentCacheActor.shared.clearCache(level: .aggressive)
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
            try TokenManager.shared.clearTokens()
            try KeychainService.shared.delete(for: .googleUserEmail)
        } catch {
            Log.error("Failed to clear tokens", category: .auth, error: error)
        }

        // Clear the sign-in flag
        UserDefaults.standard.removeObject(forKey: "hasCompletedSignIn")

        // Clear conversation cache to prevent leaking previous user's data
        ConversationCache.shared.clearAllCaches()

        // Clear attachment downloader tracking data
        AttachmentDownloader.shared.cleanupAll()

        // Clear attachment files from disk
        clearAttachmentFiles()

        // Await async cleanup tasks to ensure completion before allowing new sign-in
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await CoreDataStack.shared.resetStore()
                } catch {
                    Log.error("Failed to clear Core Data during disconnect", category: .coreData, error: error)
                }
            }

            group.addTask {
                await AttachmentCacheActor.shared.clearCache(level: .aggressive)
            }
        }
        Log.info("Disconnect cleanup completed", category: .auth)
    }

    nonisolated func withFreshToken() async throws -> String {
        // Delegate to TokenManager for centralized token management
        return try await TokenManager.shared.getCurrentToken()
    }
}

enum AuthError: LocalizedError {
    case noUser
    case noAccessToken
    case tokenPersistenceFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noUser:
            return "No authenticated user"
        case .noAccessToken:
            return "Failed to get access token"
        case .tokenPersistenceFailed(let underlyingError):
            return "Failed to save authentication tokens: \(underlyingError.localizedDescription)"
        }
    }
}