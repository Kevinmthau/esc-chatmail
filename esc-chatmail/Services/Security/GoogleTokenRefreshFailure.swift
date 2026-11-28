import AppAuthCore
import Foundation

/// The `TokenManagerError` a failed Google token refresh reaches `TokenManager`
/// as, for both of `GoogleTokenRefresher`'s refreshes: GoogleSignIn's own
/// (`refreshTokens()`) and the forced one (`GoogleForcedTokenRefresh`).
/// Neither builds a `TokenManagerError` from a refresh's error any other way
/// (`GoogleTokenRefresherTests`, `GoogleForcedTokenRefreshTests`).
///
/// AppAuth's refusal of the answer's ID token (-15 in its general domain) is
/// `refreshedIDTokenRefused`; every other failure is `refreshFailed`, which
/// `TokenManager` classifies as before (an invalid_grant is a revocation, a
/// network error is retried). AppAuth validates the ID token of every token
/// response, a refresh grant's included (`OIDAuthorizationService.m`, rule #10
/// of OpenID Connect Core 3.1.3.7): its issue time, Google's clock, may be at
/// most 600 s from the device's (`kOIDAuthorizationSessionIATMaxSkew`), its
/// expiry must not have passed by the device's clock, and its issuer and
/// audience must match. A retry changes none of those, so with the device's
/// clock more than about ten minutes off every refresh is refused, and as
/// `refreshFailed` each one was asked three times, one and then two seconds
/// apart (architecture review 2026-11, `gap-wall-clock-time#2`). Not retrying
/// it ends no outage: Gmail stays unreachable until the clock is put right.
///
/// GoogleSignIn 9.0.0 hands AppAuth's error to `refreshTokensIfNeeded`'s
/// completion unchanged, on iOS too: its EMM handling
/// (`GIDEMMSupport handleTokenFetchEMMError:completion:`) rewrites only an
/// error that carries an OAuth error response, and AppAuth builds this one
/// with a description and nothing else (`OIDErrorUtilities errorWithCode:`).
enum GoogleTokenRefreshFailure {
    static func error(for error: Error) -> TokenManagerError {
        let nsError = error as NSError
        if nsError.domain == OIDGeneralErrorDomain,
           nsError.code == OIDErrorCode.idTokenFailedValidationError.rawValue {
            return .refreshedIDTokenRefused(error)
        }
        return .refreshFailed(error)
    }
}
