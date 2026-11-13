import XCTest
@testable import esc_chatmail

/// What choosing the Mac's New Message menu command does, and which way its Mark as Read / Mark
/// as Unread command goes. The policy is plain values, so these run in the iOS suite and in
/// `Mac.xctestplan`.
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

    // MARK: - Mark as Read / Mark as Unread

    /// Revert-check: returning `.markUnread` for an empty list from
    /// `MailboxMenuPolicy.readStateCommand` makes this fail: the command would be enabled with
    /// nothing selected.
    func testReadStateCommand_nothingToActOn_isNil() {
        XCTAssertNil(MailboxMenuPolicy.readStateCommand(unreadCounts: []))
    }

    /// One conversation: the toggle its row's menu makes.
    ///
    /// Revert-check: swapping the two cases returned by `MailboxMenuPolicy.readStateCommand`
    /// makes this fail.
    func testReadStateCommand_oneConversation_isTheRowsToggle() {
        XCTAssertEqual(MailboxMenuPolicy.readStateCommand(unreadCounts: [0]), .markUnread)
        XCTAssertEqual(MailboxMenuPolicy.readStateCommand(unreadCounts: [3]), .markRead)
    }

    /// Revert-check: deciding from the first count alone in
    /// `MailboxMenuPolicy.readStateCommand` makes this fail: three selected rows with the
    /// unread one last would all be marked unread.
    func testReadStateCommand_anyUnreadAmongSeveral_marksRead() {
        XCTAssertEqual(MailboxMenuPolicy.readStateCommand(unreadCounts: [0, 0, 2]), .markRead)
        XCTAssertEqual(MailboxMenuPolicy.readStateCommand(unreadCounts: [1, 0]), .markRead)
        XCTAssertEqual(MailboxMenuPolicy.readStateCommand(unreadCounts: [0, 0, 0]), .markUnread)
    }

    /// Revert-check: returning true for every input from `MailboxMenuPolicy.changesReadState`
    /// makes this fail: Mark as Read on a mixed selection would run on the read rows too.
    func testChangesReadState_passesOverAConversationAlreadyThatWay() {
        XCTAssertTrue(MailboxMenuPolicy.changesReadState(.markRead, unreadCount: 2))
        XCTAssertFalse(MailboxMenuPolicy.changesReadState(.markRead, unreadCount: 0))
        XCTAssertTrue(MailboxMenuPolicy.changesReadState(.markUnread, unreadCount: 0))
        XCTAssertFalse(MailboxMenuPolicy.changesReadState(.markUnread, unreadCount: 1))
    }

    /// The words the row's right-click menu uses, so the two read as one command.
    ///
    /// Revert-check: returning "Mark as Unread" for `.markRead` from
    /// `MailboxMenuPolicy.readStateTitle` makes this fail.
    func testReadStateTitle_saysWhichWayTheCommandGoes() {
        XCTAssertEqual(MailboxMenuPolicy.readStateTitle(for: .markRead), "Mark as Read")
        XCTAssertEqual(MailboxMenuPolicy.readStateTitle(for: .markUnread), "Mark as Unread")
        XCTAssertEqual(MailboxMenuPolicy.readStateTitle(for: nil), "Mark as Unread")
    }
}
