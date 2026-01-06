import Foundation
import GoogleSignIn

/// Protocol for token refresh operations, enabling testability.
protocol TokenRefresherProtocol: Sendable {
    func refreshTokens() async throws -> (accessToken: String, refreshToken: String?, expirationDate: Date)
}

/// Handles Google Sign-In token refresh operations.
/// Isolates Google-specific OAuth logic from the main TokenManager.
final class GoogleTokenRefresher: TokenRefresherProtocol, @unchecked Sendable {
    private let authSession: AuthSession

    /// Initialize with an explicit AuthSession instance.
    /// Note: No default parameter to avoid MainActor-isolated access issues in Swift 6.
    init(authSession: AuthSession) {
        self.authSession = authSession
    }

    /// Refreshes tokens using Google Sign-In SDK.
    /// - Returns: A tuple containing the new access token, optional refresh token, and expiration date
    /// - Throws: TokenManagerError if refresh fails
    func refreshTokens() async throws -> (accessToken: String, refreshToken: String?, expirationDate: Date) {
        let user = await MainActor.run { authSession.currentUser }
        guard let user = user else {
            throw TokenManagerError.noValidToken
        }

        return try await withCheckedThrowingContinuation { continuation in
            user.refreshTokensIfNeeded { tokens, error in
                if let error = error {
                    continuation.resume(throwing: TokenManagerError.refreshFailed(error))
                } else if let tokens = tokens {
                    let result = (
                        accessToken: tokens.accessToken.tokenString,
                        refreshToken: tokens.refreshToken.tokenString,
                        expirationDate: tokens.accessToken.expirationDate ?? Date().addingTimeInterval(3600)
                    )
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: TokenManagerError.noValidToken)
                }
            }
        }
    }
}
