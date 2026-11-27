import AppAuthCore
import Foundation
import GoogleSignIn
import GTMAppAuth

/// Protocol for token refresh operations, enabling testability.
protocol TokenRefresherProtocol: Sendable {
    /// GoogleSignIn's own refresh: asks Google only when the access token's
    /// device-clock expiry, or the ID token's `exp`, is within 60 s, and
    /// otherwise hands back the token it holds.
    func refreshTokens() async throws -> (accessToken: String, refreshToken: String?, expirationDate: Date)
    /// A refresh that asks Google's token endpoint whatever the device's clock
    /// says. `TokenManager` asks for it only after a 401, when `refreshTokens()`
    /// handed back the very token Gmail rejected (architecture review 2026-11,
    /// `gap-wall-clock-time#2`). Required, with no default.
    func forceRefreshTokens() async throws -> (accessToken: String, refreshToken: String?, expirationDate: Date)
}

/// Handles Google Sign-In token refresh operations.
/// Isolates Google-specific OAuth logic from the main TokenManager.
final class GoogleTokenRefresher: TokenRefresherProtocol, @unchecked Sendable {
    private let authSession: AuthSession

    /// Never sent: GTMAppAuth only writes the refreshed bearer into it.
    private static let forcedRefreshProbeURL = URL(string: "https://gmail.googleapis.com/")!

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
                    continuation.resume(returning: Self.tokens(of: tokens))
                } else {
                    continuation.resume(throwing: TokenManagerError.noValidToken)
                }
            }
        }
    }

    func forceRefreshTokens() async throws -> (accessToken: String, refreshToken: String?, expirationDate: Date) {
        try await forceRefreshTokensOnMainActor()
    }

    /// GoogleSignIn 9.0.0 has no public forced refresh:
    /// `refreshTokensIfNeeded` completes with the user it holds while neither
    /// token expires within 60 s of the device's clock (`GIDGoogleUser.m`).
    /// Its `fetcherAuthorizer` is GTMAppAuth's `AuthSession` over the user's
    /// `OIDAuthState`, and AppAuth's public `setNeedsTokenRefresh()` makes
    /// the next fresh-token action ask Google whatever the clock says
    /// (`OIDAuthState.isTokenFresh`). The action is run through the
    /// session's `authorizeRequest` and not `OIDAuthState.performAction`
    /// directly, because on iOS the session's delegate is GoogleSignIn's EMM
    /// support, which adds the refresh parameters and handles the EMM errors
    /// that `refreshTokensIfNeeded` adds and handles. The user's
    /// `OIDAuthState` change delegate (`GIDGoogleUser.didChangeState`) has
    /// replaced its tokens by the time the completion runs, so they are read
    /// from the user as `refreshTokens()` reads them. GoogleSignIn's keychain
    /// copy is not rewritten, as it is not after `refreshTokensIfNeeded`.
    /// An OAuth error (invalid_grant) comes back as AppAuth's
    /// `org.openid.appauth.oauth_token` error, which `TokenManager` already
    /// classifies as revoked credentials. Main actor, as GoogleSignIn's own
    /// calls are.
    ///
    /// HONEST SCOPE: not run against Google in any test; the unit tests
    /// replace this refresher. The modules are reached as GoogleSignIn's
    /// dependencies, as `GoogleAuthTransport` reaches `AppAuthCore`, with no
    /// package product of their own in the project.
    @MainActor
    private func forceRefreshTokensOnMainActor() async throws -> (accessToken: String, refreshToken: String?, expirationDate: Date) {
        guard let user = authSession.currentUser,
              let session = user.fetcherAuthorizer as? GTMAppAuth.AuthSession else {
            throw TokenManagerError.noValidToken
        }

        session.authState.setNeedsTokenRefresh()
        let probe = NSMutableURLRequest(url: Self.forcedRefreshProbeURL)
        return try await withCheckedThrowingContinuation { continuation in
            session.authorizeRequest(probe) { error in
                if let error {
                    continuation.resume(throwing: TokenManagerError.refreshFailed(error))
                } else {
                    continuation.resume(returning: Self.tokens(of: user))
                }
            }
        }
    }

    private static func tokens(of user: GIDGoogleUser) -> (accessToken: String, refreshToken: String?, expirationDate: Date) {
        (
            accessToken: user.accessToken.tokenString,
            refreshToken: user.refreshToken.tokenString,
            expirationDate: user.accessToken.expirationDate ?? Date().addingTimeInterval(3600)
        )
    }
}
