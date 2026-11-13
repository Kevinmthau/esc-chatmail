import XCTest
@testable import esc_chatmail

/// `SettingsAppSignOutActivity`: what the windows' sign-out controllers share. How the
/// controllers use it is pinned by `SettingsAppSignOutControllerTests`.
@MainActor
final class SettingsAppSignOutActivityTests: XCTestCase {
    func testIsSigningOut_betweenBeginAndEnd_isTrue() {
        let activity = SettingsAppSignOutActivity()
        XCTAssertFalse(activity.isSigningOut)

        activity.signOutDidBegin()
        XCTAssertTrue(activity.isSigningOut)

        activity.signOutDidEnd()
        XCTAssertFalse(activity.isSigningOut)
    }

    /// Revert-check: making `runningSignOutCount` a flag that `signOutDidEnd()` clears makes
    /// this fail: the first of two sign-outs to end would enable Sign Out… over the other.
    func testIsSigningOut_twoRunning_staysTrueUntilBothEnd() {
        let activity = SettingsAppSignOutActivity()
        activity.signOutDidBegin()
        activity.signOutDidBegin()

        activity.signOutDidEnd()
        XCTAssertTrue(activity.isSigningOut)

        activity.signOutDidEnd()
        XCTAssertFalse(activity.isSigningOut)
    }

    /// A count below zero would swallow the next sign-out's begin and leave Sign Out… enabled
    /// while it runs.
    ///
    /// Revert-check: removing the `guard runningSignOutCount > 0` from
    /// `SettingsAppSignOutActivity.signOutDidEnd` makes this fail.
    func testSignOutDidEnd_withNothingRunning_doesNotGoBelowZero() {
        let activity = SettingsAppSignOutActivity()

        activity.signOutDidEnd()
        activity.signOutDidBegin()

        XCTAssertTrue(activity.isSigningOut)
    }

    func testShowFailureInFallbackWindow_noFallback_isFalse() {
        XCTAssertFalse(SettingsAppSignOutActivity().showFailureInFallbackWindow())
    }

    /// Revert-check: returning true from `SettingsAppSignOutActivity.showFailureInFallbackWindow`
    /// whatever the fallback answers makes this fail: a failure the fallback did not show
    /// would be taken as shown, and nobody would be told the account is still signed in.
    func testShowFailureInFallbackWindow_reportsWhatTheFallbackDid() {
        let activity = SettingsAppSignOutActivity()
        var shown = 0

        activity.setFailureFallback {
            shown += 1
            return true
        }
        XCTAssertTrue(activity.showFailureInFallbackWindow())
        XCTAssertEqual(shown, 1)

        activity.setFailureFallback { false }
        XCTAssertFalse(activity.showFailureInFallbackWindow())
        XCTAssertEqual(shown, 1, "a later fallback replaces the earlier one")
    }
}
