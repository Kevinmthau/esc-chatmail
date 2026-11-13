import XCTest
@testable import esc_chatmail

/// What the Mac's Settings window shows for the account (`MacSettingsPolicy`). Plain values,
/// so this runs in the iOS suite and in `Mac.xctestplan`.
final class MacSettingsPolicyTests: XCTestCase {
    func testAccountText_signedIn_isTheAddress() {
        XCTAssertEqual(
            MacSettingsPolicy.accountText(isAuthenticated: true, userEmail: " someone@example.com "),
            "someone@example.com"
        )
    }

    /// Teardown clears `isAuthenticated` and the address at different moments.
    ///
    /// Revert-check: returning `userEmail ?? signedOutAccountText` from
    /// `MacSettingsPolicy.accountText` makes this fail: the window would name an account the
    /// app has signed out of.
    func testAccountText_addressLeftFromAnEndedSession_isNotShown() {
        XCTAssertEqual(
            MacSettingsPolicy.accountText(isAuthenticated: false, userEmail: "someone@example.com"),
            "Not Signed In"
        )
    }

    func testAccountText_nobodySignedIn_saysSo() {
        XCTAssertEqual(MacSettingsPolicy.accountText(isAuthenticated: false, userEmail: nil), "Not Signed In")
        XCTAssertEqual(MacSettingsPolicy.accountText(isAuthenticated: true, userEmail: "  "), "Not Signed In")
    }

    /// The words are the iOS Settings page's, read from its `Root.plist`.
    ///
    /// Revert-check: changing `MacSettingsPolicy.signedOutAccountText` makes this fail.
    func testSignedOutAccountText_matchesTheIOSSettingsPage() throws {
        // This file is esc-chatmailTests/Platform/, so the repo root is three directories up.
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("esc-chatmail/Resources/Settings.bundle/Root.plist")
        let root = try XCTUnwrap(NSDictionary(contentsOf: plistURL) as? [String: Any])
        let specifiers = try XCTUnwrap(root["PreferenceSpecifiers"] as? [[String: Any]])
        let accountRow = try XCTUnwrap(
            specifiers.first { $0["Key"] as? String == SettingsAppPreferences.accountEmailKey }
        )

        XCTAssertEqual(accountRow["DefaultValue"] as? String, MacSettingsPolicy.signedOutAccountText)
    }
}
