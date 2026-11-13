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

    private func makeWindow(identifier: String?, hasSheet: Bool) -> NSWindow {
        let window = SheetStubWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        window.stubbedSheet = hasSheet ? NSWindow() : nil
        return window
    }
}

/// A window that answers `attachedSheet` with the window it is given.
private final class SheetStubWindow: NSWindow {
    var stubbedSheet: NSWindow?

    override var attachedSheet: NSWindow? {
        stubbedSheet
    }
}
#endif
