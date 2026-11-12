import XCTest
@testable import esc_chatmail

/// Which header each presenter gives its chat, read from the two places that build a
/// `ChatView`, and one modifier in `ChatView` that only its source shows.
///
/// `ChatView` takes its `ChatHeaderStyle` as a required argument so each presenter names its
/// own (`ChatHeaderPolicy`). Naming the wrong one is not a compile error and no policy test
/// would notice: the Mac's chat column would show the iPhone's title in its toolbar, or the
/// iPhone's chat would grow an avatar and a second bar.
///
/// HONEST SCOPE: this reads source text, as `MacConversationSidebarSourceTests` does, so it
/// runs in the iOS suite although one of the two views is Mac-only. It pins the argument each
/// call site passes and matches its spelling. What each style then draws is
/// `ChatHeaderPolicyTests`' to pin, and neither header has been seen in the Mac app.
final class ChatHeaderStyleSourceTests: XCTestCase {
    /// Revert-check: passing `headerStyle: .avatarOverNameCapsule(.mac)` to the `ChatView` in
    /// `ConversationListView` makes this fail.
    func testIOSList_pushesItsChatWithTheNavigationTitleHeader() throws {
        let chat = try chatViewCall(in: "esc-chatmail/Views/Main/ConversationListView.swift")

        XCTAssertTrue(chat.contains("headerStyle: .navigationTitle,"), chat)
        XCTAssertFalse(chat.contains(".avatarOverNameCapsule"), chat)
    }

    /// Revert-check: passing `headerStyle: .navigationTitle` to the `ChatView` in
    /// `MacMailboxDetail` makes this fail: the Mac's toolbar would show the conversation's name
    /// where Messages has the avatar, and there would be no name capsule.
    func testMacChatColumn_showsItsChatWithTheAvatarOverNameCapsuleHeaderAtTheMacsSizes() throws {
        let chat = try chatViewCall(in: "esc-chatmail/Platform/MacMailboxDetail.swift")

        XCTAssertTrue(chat.contains("headerStyle: .avatarOverNameCapsule(.mac),"), chat)
        XCTAssertFalse(chat.contains(".navigationTitle"), chat)
    }

    /// The avatar's toolbar item is taken off the toolbar's glass, and the name capsule's
    /// offset is the number measured without that glass (`ChatHeaderMetrics.mac`). The two go
    /// together: with the modifier gone the avatar moves 2 points right of the capsule and
    /// sits on a platter of glass, and nothing else would notice.
    ///
    /// Revert-check: deleting the `.macSharedBackgroundHidden(...)` line from the principal
    /// item in `ChatView.content` makes this fail.
    func testChatView_principalItem_asksThePolicyWhetherToHideItsGlass() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Views/Chat/ChatView.swift"),
            encoding: .utf8
        )
        let item = try XCTUnwrap(
            source.range(of: "ToolbarItem(placement: .principal) {"),
            "ChatView no longer has the principal item this test reads"
        )
        let nextItem = try XCTUnwrap(
            source.range(of: "ToolbarItemGroup(placement: .trailingBarEdge) {", range: item.upperBound..<source.endIndex),
            "ChatView's principal item is no longer followed by its trailing group"
        )
        let principalItem = String(source[item.lowerBound..<nextItem.lowerBound])

        XCTAssertTrue(
            principalItem.contains(
                ".macSharedBackgroundHidden(ChatHeaderPolicy.hidesPrincipalItemGlass(for: headerStyle))"
            ),
            principalItem
        )
    }

    /// The arguments of the one `ChatView(` call in a source file: from its opening parenthesis
    /// to the line that closes it at the call's own indentation.
    private func chatViewCall(in relativePath: String) throws -> String {
        let lines = try String(contentsOf: repoFile(relativePath), encoding: .utf8)
            .components(separatedBy: "\n")

        let openings = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespaces) == "ChatView("
        }
        XCTAssertEqual(openings.count, 1, "\(relativePath) no longer builds exactly one ChatView")
        let opening = try XCTUnwrap(openings.first)
        let indentation = lines[opening].prefix { $0 == " " }
        let closing = try XCTUnwrap(
            lines[(opening + 1)...].firstIndex { $0 == indentation + ")" },
            "The ChatView call in \(relativePath) has no closing line this test can find"
        )
        return lines[(opening + 1)..<closing].joined(separator: "\n")
    }

    private func repoFile(_ relativePath: String) -> URL {
        // This file is esc-chatmailTests/Platform/, so the repo root is three directories up.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
