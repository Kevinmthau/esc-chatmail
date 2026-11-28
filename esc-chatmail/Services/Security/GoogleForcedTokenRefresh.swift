import Foundation

/// The forced refresh's outcome rule, apart from GoogleSignIn and AppAuth so
/// that tests reach it (`GoogleTokenRefresher.forceRefreshTokens`; architecture
/// review 2026-11, `gap-wall-clock-time#2`).
///
/// A failed token request is a thrown error even though the user's auth state
/// still holds a token. That token is the one Gmail has just rejected: AppAuth
/// leaves the old access token in place on a network error and hands it to a
/// fresh-token action together with the error (`OIDAuthState.m`), and
/// GTMAppAuth's `authorizeRequest` drops the error whenever a token is present
/// (`AuthSession.swift`). Taken as success, the rejected token went back to
/// `TokenManager`, which never retried the transient failure. Only a request
/// that succeeded is read for tokens.
struct GoogleForcedTokenRefresh {
    typealias Tokens = (accessToken: String, refreshToken: String?, expirationDate: Date)

    /// Sends one refresh request and applies its answer to the user's auth
    /// state, then calls back with nil, or with the request's error.
    let send: (_ completion: @escaping (Error?) -> Void) -> Void
    /// The user's tokens, read only after `send` succeeded.
    let readTokens: () -> Tokens

    /// Main actor, as GoogleSignIn's own token calls are.
    @MainActor
    func run() async throws -> Tokens {
        try await withCheckedThrowingContinuation { continuation in
            send { error in
                if let error {
                    continuation.resume(throwing: TokenManagerError.refreshFailed(error))
                } else {
                    continuation.resume(returning: readTokens())
                }
            }
        }
    }
}
