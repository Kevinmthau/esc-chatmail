import AppAuthCore
import Foundation

/// The deadline on Google's token requests, the launch restore's above all.
///
/// `AuthSession.restorePreviousSignIn()` waits for GoogleSignIn's restore inside the
/// auth-transition gate, with outbound admission closed and sync quiesced. On a cold
/// launch that restore makes a token request unless the access token GoogleSignIn saved
/// has more than ten minutes left, which after an hour away is nearly every launch.
/// AppAuth sends the request through `+[NSURLSession sharedSession]`, whose request
/// timeout is 60 seconds of silence and whose resource timeout is seven days, so a
/// stalled link held the launch, the gate and every queued transition for as long as the
/// link kept trickling (architecture review 2026-11, `concurrency-model#1`).
///
/// The deadline is put on the transport and nowhere else. The wait in
/// `restorePreviousSignIn()` must never be given a timeout of its own: GoogleSignIn keeps
/// one slot for the flow in progress (`_currentOptions`), so a restore whose wait ended
/// while the SDK was still running would release the gate to an interactive sign-in,
/// which takes that slot; the restore's completion then consumed the sign-in's, and the
/// sign-in's wait, which nothing can cancel, never ended. Bounded at the transport, the
/// SDK itself reports a network error (`OIDErrorCodeNetworkError`) inside the gate, which
/// `AuthSession` treats as a failure that keeps the credentials and holds the account
/// (`AuthSession.heldAccount`, `HeldAccount`).
///
/// The bound is per request, not per restore: a restore usually makes one token request,
/// but GoogleSignIn makes two when it already has a current user (a refresh, then on
/// failure a restore from the keychain; `GIDSignIn.m` `restorePreviousSignIn`), so the
/// gate is held for at most about a minute there. That is bounded, which is what the gate
/// needs; the deadline of the restore as a whole is the sum.
///
/// The session is AppAuth's for every request it makes: the launch restore, the
/// interactive sign-in's code exchange and `GIDGoogleUser.refreshTokensIfNeeded`. Each of
/// them is one small POST, which `requestTimeout` and `resourceTimeout` leave ample room
/// for.
///
/// HONEST SCOPE: a restore whose refreshed ID token carries no profile also fetches
/// userinfo through GTMSessionFetcher, which this session does not reach. A refresh
/// returns an ID token with the profile for this app's scopes (`openid` is always
/// granted), so that fetch is not on the normal path; it keeps GTMSessionFetcher's own
/// 60-second request timeout.
enum GoogleAuthTransport {
    /// How long a token request may go without receiving data.
    static let requestTimeout: TimeInterval = 15
    /// How long a token request may take in all, retries by the system included.
    static let resourceTimeout: TimeInterval = 30

    /// A session like the shared one AppAuth used before, with the two deadlines.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        // Already the default; stated because a session that waited for
        // connectivity would hold the gate for the whole resource timeout
        // offline, where a failure at once lets the launch show the held account.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Hands AppAuth the session. Called from `configureGoogleSignIn()` in the app's
    /// initializer, before any restore or sign-in can start (`GoogleAuthTransportTests`
    /// pins the call from source).
    static func install() {
        OIDURLSessionProvider.setSession(makeSession())
    }

    /// The session AppAuth sends its requests through now. For tests, which do not
    /// import AppAuth.
    static var installedSession: URLSession {
        OIDURLSessionProvider.session()
    }
}
