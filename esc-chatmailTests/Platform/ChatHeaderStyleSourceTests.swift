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
        let chats = try chatViewCalls(in: "esc-chatmail/Views/Main/ConversationListView.swift")

        for chat in chats {
            XCTAssertTrue(chat.contains("headerStyle: .navigationTitle"), chat)
            XCTAssertFalse(chat.contains(".avatarOverNameCapsule"), chat)
        }
    }

    /// Revert-check: passing `headerStyle: .navigationTitle` to the `ChatView` in
    /// `MacMailboxDetail` makes this fail: the Mac's toolbar would show the conversation's name
    /// where Messages has the avatar, and there would be no name capsule.
    func testMacChatColumn_showsItsChatWithTheAvatarOverNameCapsuleHeaderAtTheMacsSizes() throws {
        let chats = try chatViewCalls(in: "esc-chatmail/Platform/MacMailboxDetail.swift")

        for chat in chats {
            XCTAssertTrue(chat.contains("headerStyle: .avatarOverNameCapsule(.mac)"), chat)
            XCTAssertFalse(chat.contains(".navigationTitle"), chat)
        }
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

    /// The arguments of every `ChatView(` call in a source file, each from its opening
    /// parenthesis to the one that closes it, however the call is laid out. At least one, or
    /// the test fails: a file that builds no chat has nothing to pin.
    ///
    /// Parentheses are counted as written, comments and strings included, so an unpaired one
    /// among the arguments would be miscounted; neither call has one.
    private func chatViewCalls(in relativePath: String) throws -> [String] {
        let source = try String(contentsOf: repoFile(relativePath), encoding: .utf8)
        var calls: [String] = []
        var searchStart = source.startIndex

        while let opening = source.range(of: "ChatView(", range: searchStart..<source.endIndex) {
            searchStart = opening.upperBound
            // `MacChatView(` or `makeChatView(` is some other call.
            if opening.lowerBound > source.startIndex {
                let before = source[source.index(before: opening.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" { continue }
            }

            var depth = 1
            var index = opening.upperBound
            while index < source.endIndex, depth > 0 {
                if source[index] == "(" { depth += 1 }
                if source[index] == ")" { depth -= 1 }
                if depth > 0 { index = source.index(after: index) }
            }
            XCTAssertEqual(depth, 0, "A ChatView call in \(relativePath) is never closed")
            calls.append(String(source[opening.upperBound..<index]))
        }

        XCTAssertFalse(calls.isEmpty, "\(relativePath) no longer builds a ChatView")
        return calls
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
