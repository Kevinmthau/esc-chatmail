import XCTest
@testable import esc_chatmail

/// What choosing the Mac's New Message menu command does. The policy is plain values, so these
/// run in the iOS suite and in `Mac.xctestplan`.
///
/// HONEST SCOPE: this pins the rule, not its wiring. Nothing here runs
/// `MailboxMenuActions.chooseNewMessage`, which reads `FocusedWindowSheet.isAttached` from AppKit
/// and beeps, or `MailboxCommands`, which calls it; there is no UI test target, and the Mac app
/// is not launched to check UI. The action's `newMessage` closure is private, so the command
/// cannot open the sheet any other way.
final class MailboxMenuPolicyTests: XCTestCase {
    /// A Mac window shows one sheet at a time, so New Message asked for under the reader would
    /// wait unseen and appear when the reader closed.
    ///
    /// Revert-check: making `MailboxMenuPolicy.newMessageChoice` return `.open` for every input
    /// makes this fail.
    func testNewMessageChoice_focusedWindowHasSheet_refuses() {
        XCTAssertEqual(MailboxMenuPolicy.newMessageChoice(focusedWindowHasSheet: true), .refuse)
    }

    /// Revert-check: making `MailboxMenuPolicy.newMessageChoice` return `.refuse` for every input
    /// makes this fail: Command-N would never open New Message.
    func testNewMessageChoice_noSheetAttached_opens() {
        XCTAssertEqual(MailboxMenuPolicy.newMessageChoice(focusedWindowHasSheet: false), .open)
    }
}
