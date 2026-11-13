import XCTest
@testable import esc_chatmail

/// Which window's closing quits the Mac app (`MacMainWindowPolicy`). Plain values, so this
/// runs in the iOS suite and in `Mac.xctestplan`.
final class MacMainWindowPolicyTests: XCTestCase {
    /// Revert-check: returning false for every identifier from
    /// `MacMainWindowPolicy.closingQuitsApp` makes this fail: with the Settings window open,
    /// closing the mailbox window would leave the app running.
    func testClosingQuitsApp_theMailboxWindow_quits() {
        XCTAssertTrue(MacMainWindowPolicy.closingQuitsApp(windowIdentifier: MacMainWindowPolicy.windowID))
    }

    /// The identifier SwiftUI gave the Settings window in the stand-in program, and windows
    /// with none: a sheet, a panel.
    ///
    /// Revert-check: returning true for every identifier from
    /// `MacMainWindowPolicy.closingQuitsApp` makes this fail: closing Settings, or an alert,
    /// would quit the app.
    func testClosingQuitsApp_anyOtherWindow_doesNot() {
        XCTAssertFalse(MacMainWindowPolicy.closingQuitsApp(windowIdentifier: "com_apple_SwiftUI_Settings_window"))
        XCTAssertFalse(MacMainWindowPolicy.closingQuitsApp(windowIdentifier: nil))
        XCTAssertFalse(MacMainWindowPolicy.closingQuitsApp(windowIdentifier: ""))
    }
}
