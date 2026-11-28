import AppAuthCore
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
///
/// The forced refresh helps only while the device's clock is less than about
/// ten minutes off. AppAuth validates the ID token of every token response,
/// a refresh grant's included (`OIDAuthorizationService.m`, rule #10 of
/// OpenID Connect Core 3.1.3.7): its issue time, Google's clock, may be at
/// most 600 s from the device's (`kOIDAuthorizationSessionIATMaxSkew`), and
/// Google returns an ID token on refresh for this app's `openid` scope. So
/// with the clock set back hours or days, as in the review's triggers, Google
/// issues a new token and AppAuth refuses its answer with -15. That is the
/// one failure this maps apart (`refreshError(for:)`): it is not retried, and
/// it is not a revocation. GoogleSignIn's own refresh makes the same check,
/// so with the clock more than ten minutes off the outage does not end at the
/// token's real expiry either, as the review expected; it lasts until the
/// clock is put right. Neither is changed here.
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
                    continuation.resume(throwing: Self.refreshError(for: error))
                } else {
                    continuation.resume(returning: readTokens())
                }
            }
        }
    }

    /// AppAuth's refusal of the answer's ID token (-15 in its general
    /// domain: its issue time or expiry against the device's clock, or its
    /// issuer or audience, none of which a retry changes) is
    /// `refreshedIDTokenRefused`; every other failure is `refreshFailed`,
    /// which `TokenManager` classifies as before (an invalid_grant is a
    /// revocation, a network error is retried).
    static func refreshError(for error: Error) -> TokenManagerError {
        let nsError = error as NSError
        if nsError.domain == OIDGeneralErrorDomain,
           nsError.code == OIDErrorCode.idTokenFailedValidationError.rawValue {
            return .refreshedIDTokenRefused(error)
        }
        return .refreshFailed(error)
    }
}
