#if os(macOS)
import AppKit
import XCTest
@testable import esc_chatmail

/// `SheetBehindFocusedWindow`: which window a refused Sign Out… brings to the front.
///
/// HONEST SCOPE: no sheet is shown and no window is raised. The windows are never ordered
/// in, "has a sheet attached" is a window that answers so (`SheetStubWindow`), and raising
/// is a closure the test gives. That `SignOutMenuAction.perform` asks for it on a refusal is
/// read from its source (`MacSettingsSceneSourceTests`). Nobody has chosen Sign Out… in the
/// app with the other window's confirmation behind the window in front.
@MainActor
final class SheetBehindFocusedWindowTests: XCTestCase {
    /// With the Settings window's confirmation up and the mailbox window clicked over it,
    /// Sign Out… beeped every time, with nothing on screen to say why.
    ///
    /// Revert-check: returning nil from `SheetBehindFocusedWindow.window(among:keyWindow:mainWindow:)`
    /// makes this fail.
    func testWindow_otherWindowHasSheet_isThatWindow() {
        let settings = SheetStubWindow.make(identifier: "com_apple_SwiftUI_Settings_window", hasSheet: true)
        let mailbox = SheetStubWindow.make(identifier: MacMainWindowPolicy.windowID, hasSheet: false)

        let found = SheetBehindFocusedWindow.window(
            among: [mailbox, settings],
            keyWindow: mailbox,
            mainWindow: mailbox
        )

        XCTAssertTrue(found === settings)
    }

    /// The Settings window in front and New Message open on the mailbox window behind it.
    ///
    /// Revert-check: returning `windows.first`, whatever it has attached, from
    /// `SheetBehindFocusedWindow.window(among:keyWindow:mainWindow:)` makes this fail: the
    /// window already in front would be the one raised.
    func testWindow_mailboxWindowHasSheetBehindSettings_isTheMailboxWindow() {
        let settings = SheetStubWindow.make(identifier: "com_apple_SwiftUI_Settings_window", hasSheet: false)
        let mailbox = SheetStubWindow.make(identifier: MacMainWindowPolicy.windowID, hasSheet: true)

        let found = SheetBehindFocusedWindow.window(
            among: [settings, mailbox],
            keyWindow: settings,
            mainWindow: settings
        )

        XCTAssertTrue(found === mailbox)
    }

    /// What is in the way is then in front already, and raising another window would hide it.
    /// While a sheet is up it is the key window and its window is the main window.
    ///
    /// Revert-check: dropping the `FocusedWindowSheet.isAttached` guard from
    /// `SheetBehindFocusedWindow.window(among:keyWindow:mainWindow:)` makes this fail.
    func testWindow_focusedWindowHasSheet_isNil() throws {
        let settings = SheetStubWindow.make(identifier: "com_apple_SwiftUI_Settings_window", hasSheet: true)
        let mailbox = SheetStubWindow.make(identifier: MacMainWindowPolicy.windowID, hasSheet: true)
        let mailboxSheet = try XCTUnwrap(mailbox.attachedSheet)

        XCTAssertNil(
            SheetBehindFocusedWindow.window(among: [settings, mailbox], keyWindow: mailboxSheet, mainWindow: mailbox)
        )
        // The sheet's window is read from the key window too, for a moment when no window
        // is the main one.
        XCTAssertNil(
            SheetBehindFocusedWindow.window(among: [settings, mailbox], keyWindow: mailboxSheet, mainWindow: nil)
        )
    }

    /// A refusal with no sheet anywhere (no account left to sign out) raises nothing.
    ///
    /// Revert-check: returning `windows.first`, whatever it has attached, from
    /// `SheetBehindFocusedWindow.window(among:keyWindow:mainWindow:)` makes this fail.
    func testWindow_noWindowHasSheet_isNil() {
        let settings = SheetStubWindow.make(identifier: "com_apple_SwiftUI_Settings_window", hasSheet: false)
        let mailbox = SheetStubWindow.make(identifier: MacMainWindowPolicy.windowID, hasSheet: false)

        XCTAssertNil(
            SheetBehindFocusedWindow.window(among: [settings, mailbox], keyWindow: mailbox, mainWindow: mailbox)
        )
    }

    /// Revert-check: dropping `bringForward(behind)` from
    /// `SheetBehindFocusedWindow.reveal(among:keyWindow:mainWindow:bringForward:)` makes this
    /// fail.
    func testReveal_otherWindowHasSheet_bringsThatWindowForwardOnce() {
        let settings = SheetStubWindow.make(identifier: "com_apple_SwiftUI_Settings_window", hasSheet: true)
        let mailbox = SheetStubWindow.make(identifier: MacMainWindowPolicy.windowID, hasSheet: false)
        var raised: [NSWindow] = []

        SheetBehindFocusedWindow.reveal(
            among: [mailbox, settings],
            keyWindow: mailbox,
            mainWindow: mailbox,
            bringForward: { raised.append($0) }
        )

        XCTAssertEqual(raised.count, 1)
        XCTAssertTrue(raised.first === settings)
    }

    /// Revert-check: raising `keyWindow` when no window is found, in
    /// `SheetBehindFocusedWindow.reveal(among:keyWindow:mainWindow:bringForward:)`, makes
    /// this fail.
    func testReveal_nothingBehind_bringsNothingForward() {
        let settings = SheetStubWindow.make(identifier: "com_apple_SwiftUI_Settings_window", hasSheet: false)
        let mailbox = SheetStubWindow.make(identifier: MacMainWindowPolicy.windowID, hasSheet: false)
        var raisedCount = 0

        SheetBehindFocusedWindow.reveal(
            among: [settings, mailbox],
            keyWindow: mailbox,
            mainWindow: mailbox,
            bringForward: { _ in raisedCount += 1 }
        )

        XCTAssertEqual(raisedCount, 0)
    }
}
#endif
