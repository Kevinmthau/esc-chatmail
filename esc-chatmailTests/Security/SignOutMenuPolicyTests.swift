import XCTest
@testable import esc_chatmail

/// When the Mac's Sign Out… menu command can be chosen. What choosing it does is pinned by
/// `SettingsAppSignOutControllerTests`; the menu item reading this value is `ContentView` and
/// `SignOutCommands` wiring that no test exercises (see the HONEST SCOPE note there).
final class SignOutMenuPolicyTests: XCTestCase {
    func testIsEnabled_signedInAndIdle_returnsTrue() {
        XCTAssertTrue(SignOutMenuPolicy.isEnabled(isAuthenticated: true, isSigningOut: false))
    }

    /// With nobody signed in the command has no session to end, and a request raised there would
    /// only be discarded.
    ///
    /// Revert-check: dropping `isAuthenticated &&` from `SignOutMenuPolicy.isEnabled` makes this
    /// fail.
    func testIsEnabled_signedOut_returnsFalse() {
        XCTAssertFalse(SignOutMenuPolicy.isEnabled(isAuthenticated: false, isSigningOut: false))
    }

    /// The session stays published until teardown reaches it, so `isAuthenticated` alone would
    /// leave the command enabled over the "Signing Out…" overlay.
    ///
    /// Revert-check: dropping `&& !isSigningOut` from `SignOutMenuPolicy.isEnabled` makes this
    /// fail.
    func testIsEnabled_signOutRunning_returnsFalse() {
        XCTAssertFalse(SignOutMenuPolicy.isEnabled(isAuthenticated: true, isSigningOut: true))
    }
}
