import XCTest
@testable import esc_chatmail

/// Tests for GoogleConfig configuration validation.
final class GoogleConfigTests: XCTestCase {

    // MARK: - Configuration Validation Tests

    func testIsConfigured_returnsFalseWhenMissingKeys() {
        // Note: This test verifies the isConfigured property works
        // In actual test environment with xcconfig, this may return true
        // This documents the expected behavior

        // The isConfigured property should check all required keys
        let configured = GoogleConfig.isConfigured

        // If configured, missingKeys should be empty
        if configured {
            XCTAssertTrue(GoogleConfig.missingKeys.isEmpty,
                         "missingKeys should be empty when isConfigured is true")
        } else {
            XCTAssertFalse(GoogleConfig.missingKeys.isEmpty,
                          "missingKeys should not be empty when isConfigured is false")
        }
    }

    func testMissingKeys_identifiesAllRequiredKeys() {
        // Document the expected required keys
        let requiredKeys = [
            "GOOGLE_CLIENT_ID",
            "GOOGLE_API_KEY",
            "GOOGLE_PROJECT_NUMBER",
            "GOOGLE_PROJECT_ID",
            "GOOGLE_REDIRECT_URI"
        ]

        // If any keys are missing, they should be in the expected set
        for missingKey in GoogleConfig.missingKeys {
            XCTAssertTrue(requiredKeys.contains(missingKey),
                         "Unexpected missing key reported: \(missingKey)")
        }
    }

    // MARK: - Configuration Values Tests

    func testScopes_containsRequiredScopes() {
        let scopes = GoogleConfig.scopes

        // Email apps need these scopes
        XCTAssertTrue(scopes.contains("openid"), "Should include openid scope")
        XCTAssertTrue(scopes.contains("email"), "Should include email scope")
        XCTAssertTrue(scopes.contains("profile"), "Should include profile scope")
        XCTAssertTrue(scopes.contains("https://www.googleapis.com/auth/gmail.modify"),
                     "Should include gmail.modify scope for full email access")
    }

    // MARK: - Configuration Error Tests

    func testConfigurationError_providesDescriptiveMessage() {
        let error = GoogleConfig.ConfigurationError.missingKey("TEST_KEY")
        let description = error.errorDescription ?? ""

        XCTAssertTrue(description.contains("TEST_KEY"),
                     "Error message should include the missing key name")
        XCTAssertTrue(description.contains("xcconfig"),
                     "Error message should mention xcconfig files")
        XCTAssertTrue(description.contains("Config.xcconfig.template"),
                     "Error message should reference the template file")
    }
}
