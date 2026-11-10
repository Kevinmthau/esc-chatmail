import XCTest
@testable import esc_chatmail

/// When the Mac's Sign Out… menu command can be chosen, and whether choosing it asks. What
/// asking does is pinned by `SettingsAppSignOutControllerTests`; the menu item reading these
/// values is `ContentView` and `SignOutCommands` wiring that no test exercises (see the HONEST
/// SCOPE note there).
final class SignOutMenuPolicyTests: XCTestCase {
    // MARK: - isEnabled

    func testIsEnabled_signedInAndIdle_returnsTrue() {
        XCTAssertTrue(
            SignOutMenuPolicy.isEnabled(isAuthenticated: true, holdsAccountWhileSignedOut: false, isSigningOut: false)
        )
    }

    /// With nobody signed in and nothing held, the command has no session to end.
    ///
    /// Revert-check: making `SignOutMenuPolicy.isEnabled` return `!isSigningOut` makes this fail.
    func testIsEnabled_signedOutWithNothingHeld_returnsFalse() {
        XCTAssertFalse(
            SignOutMenuPolicy.isEnabled(isAuthenticated: false, holdsAccountWhileSignedOut: false, isSigningOut: false)
        )
    }

    /// A launch restore that failed retryably shows `SignInView` over an account that is still
    /// on the Mac. iOS can sign that state out from the Settings switch; the Mac's only way is
    /// this command, so it must not be disabled there.
    ///
    /// Revert-check: dropping `|| holdsAccountWhileSignedOut` from `SignOutMenuPolicy.isEnabled`
    /// makes this fail.
    func testIsEnabled_signedOutButAccountHeld_returnsTrue() {
        XCTAssertTrue(
            SignOutMenuPolicy.isEnabled(isAuthenticated: false, holdsAccountWhileSignedOut: true, isSigningOut: false)
        )
    }

    /// The session stays published until teardown reaches it, so `isAuthenticated` alone would
    /// leave the command enabled over the "Signing Out…" overlay.
    ///
    /// Revert-check: dropping `&& !isSigningOut` from `SignOutMenuPolicy.isEnabled` makes this
    /// fail.
    func testIsEnabled_signOutRunning_returnsFalse() {
        XCTAssertFalse(
            SignOutMenuPolicy.isEnabled(isAuthenticated: true, holdsAccountWhileSignedOut: false, isSigningOut: true)
        )
        XCTAssertFalse(
            SignOutMenuPolicy.isEnabled(isAuthenticated: false, holdsAccountWhileSignedOut: true, isSigningOut: true)
        )
    }

    // MARK: - choice

    func testChoice_noSheetAndPolicyConfirms_confirms() {
        XCTAssertEqual(SignOutMenuPolicy.choice(focusedWindowHasSheet: false, decision: .confirm), .confirm)
    }

    /// The confirmation is an alert on the window, and a Mac window shows one sheet at a time:
    /// asked under New Message or the reader it stays queued and unseen, so the command looked
    /// as if it did nothing, and the alert then appeared when that sheet closed.
    ///
    /// Revert-check: dropping `!focusedWindowHasSheet` from the guard in
    /// `SignOutMenuPolicy.choice` makes this fail.
    func testChoice_focusedWindowHasSheet_refuses() {
        XCTAssertEqual(SignOutMenuPolicy.choice(focusedWindowHasSheet: true, decision: .confirm), .refuse)
    }

    /// The command is enabled from a cached answer, so it can be chosen after the account has
    /// gone (`.discardRequest`) or while a request is already being handled (`.none`). Neither
    /// may ask.
    ///
    /// Revert-check: dropping `decision == .confirm` from the guard in `SignOutMenuPolicy.choice`
    /// makes this fail.
    func testChoice_policyWouldNotAsk_refuses() {
        XCTAssertEqual(SignOutMenuPolicy.choice(focusedWindowHasSheet: false, decision: .discardRequest), .refuse)
        XCTAssertEqual(SignOutMenuPolicy.choice(focusedWindowHasSheet: false, decision: .none), .refuse)
    }
}
