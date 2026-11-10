import XCTest
@testable import esc_chatmail

/// What Cancel does in a compose sheet, and whether the sheet may be dismissed without it
/// (`ComposeCancelPolicy`). The Mac's rules are pinned here on iOS through `AppPlatform`.
///
/// HONEST SCOPE: `ComposeView` reading these values is wiring no test mounts. What the Mac does
/// with them was measured with a throwaway Mac program outside the repo that compiled this
/// policy and the compose shims (macOS 27.2, 2026-11-10): with a text field focused, Escape
/// closes a sheet by itself unless interactive dismissal is disabled; disabled, Escape presses
/// the Cancel button (or New Message's close button); with edits that raises the question, on
/// which Escape keeps editing and Return presses nothing. Nobody has seen it in the app.
final class ComposeCancelPolicyTests: XCTestCase {
    // MARK: - action

    /// iOS behavior must not change: Cancel there is always a tap on the button.
    ///
    /// Revert-check: dropping `platform == .macOS &&` from `ComposeCancelPolicy.action` makes
    /// this fail.
    func testAction_iOSWithUserEdits_discardsWithoutAsking() {
        XCTAssertEqual(ComposeCancelPolicy.action(platform: .iOS, hasUserEdits: true), .discard)
        XCTAssertEqual(ComposeCancelPolicy.action(platform: .iOS, hasUserEdits: false), .discard)
    }

    /// On the Mac Escape is Cancel, and Escape is also what closes an autocomplete list or
    /// leaves a field; a draft must not be one stray key away from gone.
    ///
    /// Revert-check: making `ComposeCancelPolicy.action` always return `.discard` makes this
    /// fail.
    func testAction_macWithUserEdits_asksFirst() {
        XCTAssertEqual(ComposeCancelPolicy.action(platform: .macOS, hasUserEdits: true), .confirmDiscard)
    }

    /// Revert-check: dropping `&& hasUserEdits` from `ComposeCancelPolicy.action` makes this
    /// fail.
    func testAction_macWithNothingTyped_discardsWithoutAsking() {
        XCTAssertEqual(ComposeCancelPolicy.action(platform: .macOS, hasUserEdits: false), .discard)
    }

    // MARK: - disablesInteractiveDismiss

    /// iOS keeps the rule it had: the sheet can be swiped down unless a send is in flight.
    ///
    /// Revert-check: making `ComposeCancelPolicy.disablesInteractiveDismiss` return true makes
    /// this fail, and so does dropping `isSending ||` from it.
    func testDisablesInteractiveDismiss_iOS_followsSending() {
        XCTAssertFalse(ComposeCancelPolicy.disablesInteractiveDismiss(platform: .iOS, isSending: false))
        XCTAssertTrue(ComposeCancelPolicy.disablesInteractiveDismiss(platform: .iOS, isSending: true))
    }

    /// Left enabled, Escape closes a Mac compose sheet whose field has the focus without
    /// pressing Cancel, so nothing could ask first.
    ///
    /// Revert-check: dropping `|| platform == .macOS` from
    /// `ComposeCancelPolicy.disablesInteractiveDismiss` makes this fail.
    func testDisablesInteractiveDismiss_mac_isAlwaysDisabled() {
        XCTAssertTrue(ComposeCancelPolicy.disablesInteractiveDismiss(platform: .macOS, isSending: false))
        XCTAssertTrue(ComposeCancelPolicy.disablesInteractiveDismiss(platform: .macOS, isSending: true))
    }
}
