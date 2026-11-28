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
    /// So this does what `refreshTokensIfNeededWithCompletion` does past that
    /// check, on the user's `OIDAuthState`, which GoogleSignIn's public
    /// `fetcherAuthorizer` (GTMAppAuth's `AuthSession`) exposes: a refresh
    /// request built by `tokenRefreshRequest(withAdditionalParameters:)`, sent
    /// with `OIDAuthorizationService.perform`, and its answer applied with
    /// `update(with:error:)`, or `update(withAuthorizationError:)` for an
    /// OAuth error, exactly as there. The user is the auth state's change
    /// delegate (`GIDGoogleUser.didChangeState`), so the user's tokens are
    /// replaced inside `update(with:error:)`, which is what
    /// `refreshTokensIfNeeded`'s own completion relies on, and they are read
    /// from the user as `refreshTokens()` reads them.
    ///
    /// Three things are deliberate:
    /// - Never GTMAppAuth's `authorizeRequest`. On iOS its delegate is
    ///   GoogleSignIn's `GIDEMMSupport`, which answers with the token
    ///   response's own extra fields, numbers among them, bridged into
    ///   `[String: String]`, a trap on the main thread (fixed upstream in
    ///   GoogleSignIn 10.0.0). And it drops the error of a failed refresh
    ///   whenever a token is present, which AppAuth leaves after a network
    ///   error: the rejected token came back as success
    ///   (`GoogleForcedTokenRefresh`).
    /// - The parameters are the last token request's own
    ///   (`lastTokenResponse.request.additionalParameters`), as
    ///   `refreshTokensIfNeeded` sends them on macOS. They hold GoogleSignIn's
    ///   EMM fields and its SDK-version and environment fields as it last sent
    ///   them, and they are strings: GoogleSignIn builds them from strings,
    ///   and a restored auth state decodes them as strings only
    ///   (`OIDTokenRequest initWithCoder:`). On iOS `refreshTokensIfNeeded`
    ///   also rewrites `device_os` and the passcode state through the private
    ///   `GIDEMMSupport`; here they are what the last token request sent, and
    ///   GoogleSignIn's next own refresh rewrites them again.
    /// - The iOS EMM error handling (`GIDEMMSupport handleTokenFetchEMMError`,
    ///   private, which can present an alert) is not run: an EMM refusal is a
    ///   failed refresh like any other.
    ///
    /// GoogleSignIn's keychain copy of the auth state is not rewritten, as it
    /// is not after `refreshTokensIfNeeded`.
    ///
    /// It helps only while the device's clock is less than about ten minutes
    /// off: AppAuth refuses an answer whose ID token was issued more than
    /// 600 s from the device's clock, refresh grants included, and that
    /// refusal is not retried (`GoogleForcedTokenRefresh`,
    /// `TokenManagerError.refreshedIDTokenRefused`).
    ///
    /// HONEST SCOPE: not run against Google in any test; the unit tests
    /// replace this refresher, and `GoogleForcedTokenRefresh` holds the one
    /// rule they can reach. The modules are reached as GoogleSignIn's
    /// dependencies, as `GoogleAuthTransport` reaches `AppAuthCore`, with no
    /// package product of their own in the project.
    @MainActor
    private func forceRefreshTokensOnMainActor() async throws -> (accessToken: String, refreshToken: String?, expirationDate: Date) {
        guard let user = authSession.currentUser,
              let session = user.fetcherAuthorizer as? GTMAppAuth.AuthSession else {
            throw TokenManagerError.noValidToken
        }
        let authState = session.authState
        // `tokenRefreshRequest(withAdditionalParameters:)` raises an
        // Objective-C exception, which Swift cannot catch, without one.
        guard authState.refreshToken != nil else {
            throw TokenManagerError.noValidToken
        }
        let parameters = authState.lastTokenResponse?.request.additionalParameters
        guard let request = authState.tokenRefreshRequest(withAdditionalParameters: parameters) else {
            throw TokenManagerError.noValidToken
        }

        return try await GoogleForcedTokenRefresh(
            send: { completion in
                OIDAuthorizationService.perform(
                    request,
                    originalAuthorizationResponse: authState.lastAuthorizationResponse
                ) { response, error in
                    if let response {
                        authState.update(with: response, error: nil)
                        completion(nil)
                        return
                    }
                    if let error, (error as NSError).domain == OIDOAuthTokenErrorDomain {
                        authState.update(withAuthorizationError: error)
                    }
                    completion(error ?? TokenManagerError.noValidToken)
                }
            },
            readTokens: { Self.tokens(of: user) }
        ).run()
    }

    private static func tokens(of user: GIDGoogleUser) -> (accessToken: String, refreshToken: String?, expirationDate: Date) {
        (
            accessToken: user.accessToken.tokenString,
            refreshToken: user.refreshToken.tokenString,
            expirationDate: user.accessToken.expirationDate ?? Date().addingTimeInterval(3600)
        )
    }
}
