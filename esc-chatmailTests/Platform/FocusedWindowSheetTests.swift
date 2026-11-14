#if os(macOS)
import AppKit
import XCTest
@testable import esc_chatmail

/// `FocusedWindowSheet`: whether the window a menu command acts on has a sheet attached.
/// Sign Out… and New Message ask nothing while it does, and a refused Sign Out… raises no
/// other window (`SheetBehindFocusedWindow`).
///
/// The rule reads three things, and each is the only one true in one of these tests. While
/// a sheet is up AppKit makes it the key window and the window under it the main one, so in
/// the app more than one is usually true at once.
///
/// HONEST SCOPE: no sheet is shown. The windows are never ordered in, and "has a sheet
/// attached" is a window that answers so (`SheetStubWindow`). Which windows AppKit makes key
/// and main while a sheet is up is the type's own comment, not something measured here.
@MainActor
final class FocusedWindowSheetTests: XCTestCase {
    /// The key window is the sheet itself.
    ///
    /// Revert-check: dropping `keyWindow?.sheetParent != nil` from
    /// `FocusedWindowSheet.isAttached(keyWindow:mainWindow:)` makes this fail.
    func testIsAttached_keyWindowIsASheet_isTrue() throws {
        let mailbox = SheetStubWindow.make(identifier: MacMainWindowPolicy.windowID, hasSheet: true)
        let sheet = try XCTUnwrap(mailbox.attachedSheet)

        XCTAssertTrue(FocusedWindowSheet.isAttached(keyWindow: sheet, mainWindow: nil))
    }

    /// The key window is the window under the sheet, which it is for a moment as a sheet
    /// comes up.
    ///
    /// Revert-check: dropping `keyWindow?.attachedSheet != nil` from
    /// `FocusedWindowSheet.isAttached(keyWindow:mainWindow:)` makes this fail.
    func testIsAttached_keyWindowHasASheet_isTrue() {
        let mailbox = SheetStubWindow.make(identifier: MacMainWindowPolicy.windowID, hasSheet: true)

        XCTAssertTrue(FocusedWindowSheet.isAttached(keyWindow: mailbox, mainWindow: nil))
    }

    /// A panel that can be key but not main (the About window) is in front of a window with
    /// a sheet.
    ///
    /// Revert-check: dropping `mainWindow?.attachedSheet != nil` from
    /// `FocusedWindowSheet.isAttached(keyWindow:mainWindow:)` makes this fail.
    func testIsAttached_mainWindowHasASheetUnderAnotherKeyWindow_isTrue() {
        let about = SheetStubWindow.make(identifier: nil, hasSheet: false)
        let mailbox = SheetStubWindow.make(identifier: MacMainWindowPolicy.windowID, hasSheet: true)

        XCTAssertTrue(FocusedWindowSheet.isAttached(keyWindow: about, mainWindow: mailbox))
    }

    /// A sheet on a window that is neither key nor main is not this rule's to see
    /// (`MailboxWindowSheet`, `SheetBehindFocusedWindow`).
    ///
    /// Revert-check: returning true from
    /// `FocusedWindowSheet.isAttached(keyWindow:mainWindow:)` makes this fail: Sign Out… and
    /// New Message would ask nothing for as long as the app runs.
    func testIsAttached_noSheetOnTheKeyOrMainWindow_isFalse() {
        let settings = SheetStubWindow.make(identifier: "com_apple_SwiftUI_Settings_window", hasSheet: false)
        let mailbox = SheetStubWindow.make(identifier: MacMainWindowPolicy.windowID, hasSheet: true)

        XCTAssertFalse(FocusedWindowSheet.isAttached(keyWindow: settings, mainWindow: settings))
        XCTAssertFalse(FocusedWindowSheet.isAttached(keyWindow: nil, mainWindow: nil))
        XCTAssertNotNil(mailbox.attachedSheet)
    }
}
#endif
