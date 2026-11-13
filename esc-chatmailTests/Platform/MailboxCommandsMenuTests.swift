#if os(macOS)
import AppKit
import XCTest
@testable import esc_chatmail

/// The Mailbox menu the app really builds, read from the menu bar of the Mac test host, which
/// is the app itself: `MailboxCommands` is on its scene, so its items are in `NSApp.mainMenu`
/// (measured in the sandboxed test host on macOS 27.2, 2026-11-13).
///
/// HONEST SCOPE: this pins that the item is in the menu with its shortcut and that nothing
/// else in the menu bar has that shortcut. No item is chosen. The host's window never has the
/// keyboard, so the focused window's actions never reach the menu here: the item's title under
/// a selection, and what choosing it does, are pinned by `MailboxMenuPolicyTests`,
/// `ConversationListViewModelTests` and `MailboxCommandsSourceTests`, and nothing has been seen
/// in the app.
@MainActor
final class MailboxCommandsMenuTests: XCTestCase {
    private static let readStateModifiers: NSEvent.ModifierFlags = [.command, .shift]

    /// Revert-check: deleting `.keyboardShortcut("u", modifiers: [.command, .shift])` from
    /// `MailboxCommands.body` makes this fail.
    func testMailboxMenu_hasTheReadStateItemWithCommandShiftU() throws {
        let item = try XCTUnwrap(
            try mailboxMenu().items.first(where: Self.hasReadStateShortcut),
            "The Mailbox menu has no item with Command-Shift-U"
        )

        XCTAssertTrue(
            [
                MailboxMenuPolicy.readStateTitle(for: .markRead),
                MailboxMenuPolicy.readStateTitle(for: .markUnread)
            ].contains(item.title),
            item.title
        )
    }

    /// The read-state item stands apart from Get New Mail and Search.
    ///
    /// Revert-check: deleting the `Divider()` from `MailboxCommands.body` makes this fail.
    func testMailboxMenu_readStateItemFollowsASeparator() throws {
        let items = try mailboxMenu().items
        let index = try XCTUnwrap(items.firstIndex(where: Self.hasReadStateShortcut))

        XCTAssertGreaterThan(index, 0)
        XCTAssertTrue(items[index - 1].isSeparatorItem, items.map(\.title).description)
    }

    /// A shortcut two items share goes to whichever the menu bar finds first.
    ///
    /// HONEST SCOPE: there is no production line to revert; this fails if a later command, or
    /// a system menu, takes Command-Shift-U as well.
    func testMenuBar_nothingElseHasCommandShiftU() throws {
        let mainMenu = try XCTUnwrap(NSApp.mainMenu, "The test host has no menu bar")

        let holders = Self.allItems(in: mainMenu).filter(Self.hasReadStateShortcut)

        XCTAssertEqual(holders.map(\.title).count, 1, holders.map(\.title).description)
    }

    // MARK: - Helpers

    private func mailboxMenu() throws -> NSMenu {
        let mainMenu = try XCTUnwrap(NSApp.mainMenu, "The test host has no menu bar")
        let mailbox = try XCTUnwrap(
            mainMenu.items.first(where: { $0.title == "Mailbox" })?.submenu,
            "The menu bar has no Mailbox menu: \(mainMenu.items.map(\.title))"
        )
        return mailbox
    }

    private static func hasReadStateShortcut(_ item: NSMenuItem) -> Bool {
        item.keyEquivalent.lowercased() == "u"
            && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == readStateModifiers
    }

    private static func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allItems(in:)) ?? [])
        }
    }
}
#endif
