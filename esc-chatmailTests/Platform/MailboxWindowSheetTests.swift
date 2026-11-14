#if os(macOS)
import AppKit
import XCTest
@testable import esc_chatmail

/// `MailboxWindowSheet`: whether the mailbox window has a sheet attached, whichever window
/// has the focus.
///
/// HONEST SCOPE: no sheet is shown. The windows are never ordered in, and "has a sheet
/// attached" is a window that answers so (`SheetStubWindow`), because AppKit attaches a real
/// sheet only to a window on screen. That the app's mailbox window has the identifier asked
/// for is read from the test host's own window by `MacMainWindowCloseObserverTests`. Nobody
/// has chosen Sign Out… in the Settings window with a sheet on the mailbox window.
@MainActor
final class MailboxWindowSheetTests: XCTestCase {
    /// Revert-check: making `MailboxWindowSheet.isAttached(among:)` return false makes this
    /// fail: Sign Out… in the Settings window would close New Message on the mailbox window.
    func testIsAttached_mailboxWindowHasSheet_isTrue() {
        let settings = makeWindow(identifier: "com_apple_SwiftUI_Settings_window", hasSheet: false)
        let mailbox = makeWindow(identifier: MacMainWindowPolicy.windowID, hasSheet: true)

        XCTAssertTrue(MailboxWindowSheet.isAttached(among: [settings, mailbox]))
    }

    /// Revert-check: dropping `&& window.attachedSheet != nil` from
    /// `MailboxWindowSheet.isAttached(among:)` makes this fail: Sign Out… would ask nothing
    /// in either window for as long as the app runs.
    func testIsAttached_mailboxWindowHasNoSheet_isFalse() {
        let mailbox = makeWindow(identifier: MacMainWindowPolicy.windowID, hasSheet: false)

        XCTAssertFalse(MailboxWindowSheet.isAttached(among: [mailbox]))
        XCTAssertFalse(MailboxWindowSheet.isAttached(among: []))
    }

    /// The Settings window's own alert is `FocusedWindowSheet`'s to see, and a sheet on a
    /// window with no identifier is not the mailbox's.
    ///
    /// Revert-check: dropping the `MacMainWindowPolicy.isMailboxWindow` term from
    /// `MailboxWindowSheet.isAttached(among:)` makes this fail.
    func testIsAttached_onlyAnotherWindowHasSheet_isFalse() {
        let settings = makeWindow(identifier: "com_apple_SwiftUI_Settings_window", hasSheet: true)
        let unnamed = makeWindow(identifier: nil, hasSheet: true)
        let mailbox = makeWindow(identifier: MacMainWindowPolicy.windowID, hasSheet: false)

        XCTAssertFalse(MailboxWindowSheet.isAttached(among: [settings, unnamed, mailbox]))
    }

    /// Asked when the Settings window's confirmation is answered: New Message can be opened
    /// on the mailbox window while that confirmation is up.
    ///
    /// Revert-check: returning false from
    /// `MailboxWindowSheet.refusesSignOutConfirmedElsewhere(among:beep:)` makes this fail,
    /// and so does dropping its `beep()`: the answer would look ignored.
    func testRefusesSignOutConfirmedElsewhere_mailboxWindowHasSheet_refusesAndBeeps() {
        let settings = makeWindow(identifier: "com_apple_SwiftUI_Settings_window", hasSheet: false)
        let mailbox = makeWindow(identifier: MacMainWindowPolicy.windowID, hasSheet: true)
        var beepCount = 0

        let refuses = MailboxWindowSheet.refusesSignOutConfirmedElsewhere(
            among: [settings, mailbox],
            beep: { beepCount += 1 }
        )

        XCTAssertTrue(refuses)
        XCTAssertEqual(beepCount, 1)
    }

    /// Revert-check: returning true whatever the windows are, or beeping before the look,
    /// in `MailboxWindowSheet.refusesSignOutConfirmedElsewhere(among:beep:)` makes this fail:
    /// the Settings window could never sign out, or every sign-out there would beep.
    func testRefusesSignOutConfirmedElsewhere_noSheetOnTheMailboxWindow_neitherRefusesNorBeeps() {
        // The confirmation being answered is itself a sheet, on the Settings window.
        let settings = makeWindow(identifier: "com_apple_SwiftUI_Settings_window", hasSheet: true)
        let mailbox = makeWindow(identifier: MacMainWindowPolicy.windowID, hasSheet: false)
        var beepCount = 0

        let refuses = MailboxWindowSheet.refusesSignOutConfirmedElsewhere(
            among: [settings, mailbox],
            beep: { beepCount += 1 }
        )

        XCTAssertFalse(refuses)
        XCTAssertEqual(beepCount, 0)
    }

    private func makeWindow(identifier: String?, hasSheet: Bool) -> NSWindow {
        SheetStubWindow.make(identifier: identifier, hasSheet: hasSheet)
    }
}
#endif
