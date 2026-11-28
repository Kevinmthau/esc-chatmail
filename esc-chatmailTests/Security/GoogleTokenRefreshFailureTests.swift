import XCTest
@testable import esc_chatmail

/// `GoogleTokenRefreshFailure`, which both of `GoogleTokenRefresher`'s
/// refreshes throw through (architecture review 2026-11,
/// `gap-wall-clock-time#2`). AppAuth refuses Google's answer when its ID token
/// was issued more than 600 s from the device's clock, and as `refreshFailed`
/// `TokenManager` asked again twice, though no retry changes the clock.
final class GoogleTokenRefreshFailureTests: XCTestCase {

    // Revert-check: fails if `GoogleTokenRefreshFailure.error(for:)` stops
    // mapping AppAuth's -15 apart: it would be `refreshFailed`, which
    // `TokenManager` retries.
    func testError_idTokenFailedValidationInAppAuthsGeneralDomain_isRefreshedIDTokenRefused() {
        let skewRefusal = NSError(
            domain: "org.openid.appauth.general",
            code: -15,
            userInfo: [NSLocalizedDescriptionKey: "Issued at time is more than 600 seconds before or after the current time"]
        )

        guard case .refreshedIDTokenRefused(let underlying) = GoogleTokenRefreshFailure.error(for: skewRefusal) else {
            return XCTFail("AppAuth's ID-token refusal is not a refresh to retry")
        }
        XCTAssertEqual((underlying as NSError).domain, "org.openid.appauth.general")
        XCTAssertEqual((underlying as NSError).code, -15)
    }

    // Revert-check: fails if `GoogleTokenRefreshFailure.error(for:)` matches
    // the code without AppAuth's general domain: an OAuth error, whose
    // classification (invalid_grant as a revocation) runs on `refreshFailed`,
    // would be mapped apart.
    func testError_otherAppAuthFailures_stayRefreshFailures() {
        let parsingError = NSError(domain: "org.openid.appauth.general", code: -14)
        let oauthError = NSError(domain: "org.openid.appauth.oauth_token", code: -15)
        let transportError = NSError(
            domain: "org.openid.appauth.general",
            code: -5,
            userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)]
        )

        for error in [parsingError, oauthError, transportError] {
            guard case .refreshFailed(let underlying) = GoogleTokenRefreshFailure.error(for: error) else {
                return XCTFail("Only -15 in AppAuth's general domain is mapped apart: \(error)")
            }
            XCTAssertEqual((underlying as NSError).domain, error.domain)
            XCTAssertEqual((underlying as NSError).code, error.code)
        }
    }
}
