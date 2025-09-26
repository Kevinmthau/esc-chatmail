import Foundation
import GoogleSignIn
import UIKit

@MainActor
final class AuthSession: ObservableObject, @unchecked Sendable {
    static let shared = AuthSession()
    
    @Published var isAuthenticated = false
    @Published var currentUser: GIDGoogleUser?
    @Published var userEmail: String?
    @Published var userName: String?
    @Published var accessToken: String?
    
    private init() {
        // Always try to restore previous sign-in
        // The fresh install check in esc_chatmailApp will handle clearing on app deletion
        restorePreviousSignIn()
    }
    
    var refreshToken: String? {
        currentUser?.refreshToken.tokenString
    }
    
    func restorePreviousSignIn() {
        // First check if we have a valid previous session
        if GIDSignIn.sharedInstance.hasPreviousSignIn() {
            GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, error in
                DispatchQueue.main.async {
                    if let user = user {
                        self?.currentUser = user
                        self?.userEmail = user.profile?.email
                        self?.userName = user.profile?.name
                        self?.isAuthenticated = true
                        self?.accessToken = user.accessToken.tokenString
                    }
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
                    self?.currentUser = result.user
                    self?.userEmail = result.user.profile?.email
                    self?.userName = result.user.profile?.name
                    self?.isAuthenticated = true
                    self?.accessToken = result.user.accessToken.tokenString

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
                    } catch {
                        print("Failed to save tokens: \(error)")
                    }

                    // Mark that user has successfully signed in
                    UserDefaults.standard.set(true, forKey: "hasCompletedSignIn")
                }

                continuation.resume()
            }
        }
    }
    
    @MainActor
    func signOut() {
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
            print("Failed to clear tokens: \(error)")
        }

        // Clear the sign-in flag
        UserDefaults.standard.removeObject(forKey: "hasCompletedSignIn")

        // Clear all Core Data (emails, conversations, etc.)
        Task {
            do {
                try await CoreDataStack.shared.resetStore()
            } catch {
                print("Failed to clear Core Data: \(error)")
            }
        }

        // Clear all attachment caches
        AttachmentCache.shared.clearCache(level: .aggressive)

        // Clear attachment files from disk
        clearAttachmentFiles()
    }

    private func clearAttachmentFiles() {
        let fileManager = FileManager.default

        // Get app support directory
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        // Clear Attachments directory
        let attachmentsURL = appSupportURL.appendingPathComponent("Attachments")
        if fileManager.fileExists(atPath: attachmentsURL.path) {
            try? fileManager.removeItem(at: attachmentsURL)
        }

        // Clear Previews directory
        let previewsURL = appSupportURL.appendingPathComponent("Previews")
        if fileManager.fileExists(atPath: previewsURL.path) {
            try? fileManager.removeItem(at: previewsURL)
        }

        // Clear any cache directories
        if let cacheURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let attachmentCacheURL = cacheURL.appendingPathComponent("AttachmentCache")
            if fileManager.fileExists(atPath: attachmentCacheURL.path) {
                try? fileManager.removeItem(at: attachmentCacheURL)
            }
        }
    }

    @MainActor
    func signOutAndDisconnect(completion: ((Error?) -> Void)? = nil) {
        // First sign out
        GIDSignIn.sharedInstance.signOut()

        // Then disconnect to revoke tokens
        GIDSignIn.sharedInstance.disconnect { [weak self] error in
            Task { @MainActor in
                guard let self = self else {
                    completion?(error)
                    return
                }

                // Clear local state
                self.currentUser = nil
                self.userEmail = nil
                self.userName = nil
                self.isAuthenticated = false
                self.accessToken = nil

                completion?(error)
            }
        }

        // Clear local state immediately as well
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
            print("Failed to clear tokens: \(error)")
        }

        // Clear the sign-in flag
        UserDefaults.standard.removeObject(forKey: "hasCompletedSignIn")

        // Clear all Core Data (emails, conversations, etc.)
        Task {
            do {
                try await CoreDataStack.shared.resetStore()
            } catch {
                print("Failed to clear Core Data: \(error)")
            }
        }

        // Clear all attachment caches
        AttachmentCache.shared.clearCache(level: .aggressive)

        // Clear attachment files from disk
        clearAttachmentFiles()
    }
    
    nonisolated func withFreshToken() async throws -> String {
        // Delegate to TokenManager for centralized token management
        return try await TokenManager.shared.getCurrentToken()
    }
}

enum AuthError: LocalizedError {
    case noUser
    case noAccessToken
    
    var errorDescription: String? {
        switch self {
        case .noUser:
            return "No authenticated user"
        case .noAccessToken:
            return "Failed to get access token"
        }
    }
}