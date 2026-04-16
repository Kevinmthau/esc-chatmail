import XCTest
@testable import esc_chatmail

final class TokenManagerErrorTests: XCTestCase {

    // MARK: - errorDescription

    func testErrorDescription_noValidToken_isDescriptive() {
        XCTAssertEqual(TokenManagerError.noValidToken.errorDescription, "No valid authentication token available")
    }

    func testErrorDescription_refreshFailed_includesUnderlying() {
        let underlying = NSError(domain: "T", code: 1, userInfo: [NSLocalizedDescriptionKey: "oops"])
        let error = TokenManagerError.refreshFailed(underlying)
        XCTAssertTrue(error.errorDescription?.contains("oops") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("refresh") ?? false)
    }

    func testErrorDescription_networkUnavailable() {
        XCTAssertEqual(TokenManagerError.networkUnavailable.errorDescription, "Network connection unavailable")
    }

    func testErrorDescription_rateLimitExceeded() {
        XCTAssertTrue(TokenManagerError.rateLimitExceeded.errorDescription?.contains("Rate limit") ?? false)
    }

    func testErrorDescription_invalidCredentials_suggestsSignInAgain() {
        XCTAssertTrue(TokenManagerError.invalidCredentials.errorDescription?.contains("Invalid credentials") ?? false)
    }

    func testErrorDescription_tokenExpired() {
        XCTAssertTrue(TokenManagerError.tokenExpired.errorDescription?.contains("expired") ?? false)
    }

    // MARK: - recoverySuggestion

    func testRecoverySuggestion_authFailures_tellUserToSignInAgain() {
        let cases: [TokenManagerError] = [.noValidToken, .invalidCredentials, .tokenExpired]
        for error in cases {
            let suggestion = error.recoverySuggestion ?? ""
            XCTAssertTrue(suggestion.lowercased().contains("sign in"),
                          "Expected sign-in suggestion for \(error), got: \(suggestion)")
        }
    }

    func testRecoverySuggestion_refreshFailed_recommendsCheckingNetwork() {
        let suggestion = TokenManagerError.refreshFailed(NSError(domain: "", code: 0)).recoverySuggestion ?? ""
        XCTAssertTrue(suggestion.lowercased().contains("connection"))
    }

    func testRecoverySuggestion_networkUnavailable_recommendsCheckingConnection() {
        let suggestion = TokenManagerError.networkUnavailable.recoverySuggestion ?? ""
        XCTAssertTrue(suggestion.lowercased().contains("connection"))
    }

    func testRecoverySuggestion_rateLimitExceeded_recommendsWaiting() {
        let suggestion = TokenManagerError.rateLimitExceeded.recoverySuggestion ?? ""
        XCTAssertTrue(suggestion.lowercased().contains("wait"))
    }
}
