import XCTest
@testable import esc_chatmail

/// The Mailbox menu's Mark as Read / Mark as Unread command (Command-Shift-U), read from the
/// source of `MailboxCommands` and of the sidebar that gives it what to act on.
///
/// HONEST SCOPE: this reads source text, as `MacConversationSidebarSourceTests` does, so it runs
/// in the iOS suite and in CI although both files are Mac-only. It pins the shortcut, that the
/// item's title and its enabled state come from the focused window's actions, and that the
/// sidebar builds those from one set of targets. It matches the spelling of the source, so
/// renaming a local fails it too. The command itself is not run by any test: its focused value
/// reaches the menu only from a window that has the keyboard, which the test host's windows
/// never have. Nothing has been seen in the app.
final class MailboxCommandsSourceTests: XCTestCase {
    /// Mail's and Messages' shortcut for the same command.
    ///
    /// Revert-check: deleting `.keyboardShortcut("u", modifiers: [.command, .shift])` from
    /// `MailboxCommands.body` makes this fail.
    func testReadStateItem_hasCommandShiftU() throws {
        let item = try readStateItemSource()

        XCTAssertTrue(item.contains(#".keyboardShortcut("u", modifiers: [.command, .shift])"#), item)
    }

    /// Revert-check: giving the button a fixed title in `MailboxCommands.body` makes this
    /// fail: the item would read Mark as Unread over an unread conversation.
    func testReadStateItem_titleSaysWhichWayItGoes() throws {
        let item = try readStateItemSource()

        XCTAssertTrue(
            item.contains("Button(MailboxMenuPolicy.readStateTitle(for: actions?.readState)) {"),
            item
        )
        XCTAssertTrue(item.contains("actions?.changeReadState()"), item)
    }

    /// Revert-check: changing the item's `.disabled(actions?.readState == nil)` to
    /// `.disabled(actions == nil)` in `MailboxCommands.body` makes this fail: the item would
    /// be enabled, and do nothing, with no conversation selected.
    func testReadStateItem_isDisabledWithNothingToActOn() throws {
        let item = try readStateItemSource()

        XCTAssertTrue(item.contains(".disabled(actions?.readState == nil)"), item)
    }

    /// The title and the action must be about the same conversations.
    ///
    /// Revert-check: passing `selection` in place of `readStateTargets` to either argument in
    /// `MacConversationSidebar.body` makes this fail: with several rows selected and a search
    /// on, the command would change rows the list is not showing.
    func testSidebar_titleAndActionShareOneSetOfTargets() throws {
        let sidebar = try source(named: "MacConversationSidebar.swift")

        XCTAssertTrue(
            sidebar.contains("let readStateTargets = MacSidebarSelectionPolicy.readStateTargets("),
            "MacConversationSidebar no longer decides the command's targets the way this test reads them"
        )
        XCTAssertTrue(
            sidebar.contains("readState: viewModel.readStateCommand(forConversationsWithIDs: readStateTargets),")
        )
        XCTAssertTrue(
            sidebar.contains(
                "changeReadState: { viewModel.changeReadState(ofConversationsWithIDs: readStateTargets) }"
            )
        )
    }

    // MARK: - Source

    /// The source of the read-state item: from the menu's divider to the end of the menu.
    private func readStateItemSource() throws -> String {
        let commands = try source(named: "MailboxCommands.swift")
        let start = try XCTUnwrap(
            commands.range(of: "Divider()"),
            "MailboxCommands no longer has the divider this test reads from"
        )
        return String(commands[start.upperBound...])
    }

    private func source(named name: String) throws -> String {
        // This file is esc-chatmailTests/Platform/, so the repo root is three directories up.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("esc-chatmail/Platform/\(name)")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
