import XCTest
@testable import esc_chatmail

/// `GoogleForcedTokenRefresh`, the forced refresh's outcome rule, without
/// GoogleSignIn or AppAuth (architecture review 2026-11,
/// `gap-wall-clock-time#2`). After a network error AppAuth leaves the old
/// access token in the user's auth state, so a rule that read the state
/// whenever it held a token handed `TokenManager` the token Gmail had just
/// rejected, as a success it never retried.
@MainActor
final class GoogleForcedTokenRefreshTests: XCTestCase {

    private static let heldTokens: GoogleForcedTokenRefresh.Tokens = (
        accessToken: "rejected-access-token",
        refreshToken: "refresh-token",
        expirationDate: Date(timeIntervalSince1970: 1_800_000_000)
    )

    // Revert-check: fails if `GoogleForcedTokenRefresh.run` reads the user's
    // tokens when `send` reports an error (as GTMAppAuth's `authorizeRequest`
    // did whenever a token was present): the rejected token would come back
    // as a successful refresh.
    func testRun_requestFailsInTransportWhileTheOldTokenIsHeld_throwsAndReadsNoTokens() async {
        let transportError = NSError(
            domain: "org.openid.appauth.general",
            code: -5,
            userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)]
        )
        var tokenReads = 0
        let refresh = GoogleForcedTokenRefresh(
            send: { completion in completion(transportError) },
            readTokens: {
                tokenReads += 1
                return Self.heldTokens
            }
        )

        do {
            let tokens = try await refresh.run()
            XCTFail("Expected the transport error, got \(tokens.accessToken)")
        } catch TokenManagerError.refreshFailed(let underlying) {
            let nsError = underlying as NSError
            XCTAssertEqual(nsError.domain, "org.openid.appauth.general")
            XCTAssertEqual(nsError.code, -5)
        } catch {
            XCTFail("Expected TokenManagerError.refreshFailed, got \(error)")
        }
        XCTAssertEqual(tokenReads, 0, "A failed request is never read for tokens")
    }

    // Revert-check: fails if `GoogleForcedTokenRefresh.refreshError(for:)`
    // stops mapping AppAuth's -15 apart: it would be `refreshFailed`, which
    // `TokenManager` retries, three token requests that the device's clock
    // refuses each time.
    func testRun_idTokenIssuedOutsideTheAllowedSkew_isRefusedNotATransientFailure() async {
        let skewRefusal = NSError(
            domain: "org.openid.appauth.general",
            code: -15,
            userInfo: [NSLocalizedDescriptionKey: "Issued at time is more than 600 seconds before or after the current time"]
        )
        let refresh = GoogleForcedTokenRefresh(
            send: { completion in completion(skewRefusal) },
            readTokens: { Self.heldTokens }
        )

        do {
            let tokens = try await refresh.run()
            XCTFail("Expected the refusal, got \(tokens.accessToken)")
        } catch TokenManagerError.refreshedIDTokenRefused(let underlying) {
            XCTAssertEqual((underlying as NSError).code, -15)
        } catch {
            XCTFail("Expected TokenManagerError.refreshedIDTokenRefused, got \(error)")
        }
    }

    // Revert-check: fails if `refreshError(for:)` matches the code without
    // AppAuth's general domain: an OAuth error, whose classification
    // (invalid_grant as a revocation) runs on `refreshFailed`, would be
    // mapped apart.
    func testRefreshError_otherAppAuthFailures_stayRefreshFailures() {
        let parsingError = NSError(domain: "org.openid.appauth.general", code: -14)
        let oauthError = NSError(domain: "org.openid.appauth.oauth_token", code: -15)

        guard case .refreshFailed = GoogleForcedTokenRefresh.refreshError(for: parsingError) else {
            return XCTFail("Only -15 in AppAuth's general domain is mapped apart")
        }
        guard case .refreshFailed = GoogleForcedTokenRefresh.refreshError(for: oauthError) else {
            return XCTFail("An OAuth error keeps its own classification (invalid_grant is a revocation)")
        }
    }

    func testRun_requestSucceeds_returnsTheTokensItLeft() async throws {
        let refreshed: GoogleForcedTokenRefresh.Tokens = (
            accessToken: "refreshed-access-token",
            refreshToken: "refresh-token",
            expirationDate: Date(timeIntervalSince1970: 1_800_003_600)
        )
        var held = Self.heldTokens
        let refresh = GoogleForcedTokenRefresh(
            send: { completion in
                held = refreshed
                completion(nil)
            },
            readTokens: { held }
        )

        let tokens = try await refresh.run()

        XCTAssertEqual(tokens.accessToken, "refreshed-access-token")
        XCTAssertEqual(tokens.expirationDate, refreshed.expirationDate)
    }
}
