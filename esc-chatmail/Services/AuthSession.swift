import Foundation
import GoogleSignIn
import UIKit

class AuthSession: ObservableObject {
    static let shared = AuthSession()
    
    @Published var isAuthenticated = false
    @Published var currentUser: GIDGoogleUser?
    @Published var userEmail: String?
    @Published var accessToken: String?
    
    private init() {
        // Only restore previous sign-in if this is not a fresh install
        if UserDefaults.standard.bool(forKey: "hasRunBefore") {
            restorePreviousSignIn()
        }
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
                
                DispatchQueue.main.async {
                    self?.currentUser = result.user
                    self?.userEmail = result.user.profile?.email
                    self?.isAuthenticated = true
                    self?.accessToken = result.user.accessToken.tokenString
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
        isAuthenticated = false
        accessToken = nil
    }
    
    @MainActor
    func signOutAndDisconnect(completion: ((Error?) -> Void)? = nil) {
        // First sign out
        GIDSignIn.sharedInstance.signOut()
        
        // Then disconnect to revoke tokens
        GIDSignIn.sharedInstance.disconnect { error in
            completion?(error)
        }
        
        // Clear local state
        currentUser = nil
        userEmail = nil
        isAuthenticated = false
        accessToken = nil
    }
    
    func withFreshToken() async throws -> String {
        guard let user = currentUser else {
            throw AuthError.noUser
        }
        
        do {
            let tokens = try await user.refreshTokensIfNeeded()
            await MainActor.run {
                self.accessToken = tokens.accessToken.tokenString
            }
            return tokens.accessToken.tokenString
        } catch {
            throw AuthError.noAccessToken
        }
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