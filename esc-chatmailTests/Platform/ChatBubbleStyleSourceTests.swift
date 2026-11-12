import XCTest
@testable import esc_chatmail

/// Which bubble style each presenter gives its chat, and the wiring between the transcript and
/// the bubble that only source shows.
///
/// `ChatView` takes its `MessageBubbleStyle` as a required argument so each presenter names
/// its own. Naming the wrong one is not a compile error and no policy test would notice: the
/// iPhone's transcript would lose its timestamps and grow tails, or the Mac's would be the
/// iPhone's.
///
/// HONEST SCOPE: this reads source text, as `ChatHeaderStyleSourceTests` does, so it runs in
/// the iOS suite although one of the views is Mac-only. It pins what each call passes and
/// matches its spelling. What a style then draws is `MessageBubbleStyleTests`' and the policy
/// suites' to pin, and the Mac's transcript has not been seen in the app.
final class ChatBubbleStyleSourceTests: XCTestCase {
    /// Revert-check: passing `bubbleStyle: .mac` to the `ChatView` in `ConversationListView`
    /// makes this fail.
    func testIOSList_pushesItsChatWithTheStandardBubbles() throws {
        let chat = try call("ChatView(", in: "esc-chatmail/Views/Main/ConversationListView.swift")

        XCTAssertTrue(chat.contains("bubbleStyle: .standard,"), chat)
        XCTAssertFalse(chat.contains(".mac"), chat)
    }

    /// Revert-check: passing `bubbleStyle: .standard` to the `ChatView` in `MacMailboxDetail`
    /// makes this fail.
    func testMacChatColumn_showsItsChatWithTheMacsBubbles() throws {
        let chat = try call("ChatView(", in: "esc-chatmail/Platform/MacMailboxDetail.swift")

        XCTAssertTrue(chat.contains("bubbleStyle: .mac,"), chat)
        XCTAssertFalse(chat.contains(".standard"), chat)
    }

    /// The style reaches the bubble, with the row's place in its run and the transcript's
    /// width. Without `style:` the bubble's default is the iPhone's, on the Mac too.
    ///
    /// Revert-check: deleting `style:` or `transcriptWidth:` from the `MessageBubble(` call
    /// in `ChatMessagesView` makes this fail. Deleting `runPlacement:` does not compile (the
    /// value is then unused, and warnings are errors), so the assertion on it is a second guard.
    func testTranscript_handsEachBubbleItsStyleItsRunPlacementAndTheTranscriptsWidth() throws {
        let bubble = try call("MessageBubble(", in: "esc-chatmail/Views/Chat/ChatMessagesView.swift")

        XCTAssertTrue(bubble.contains("style: bubbleStyle,"), bubble)
        XCTAssertTrue(bubble.contains("runPlacement: runPlacement,"), bubble)
        XCTAssertTrue(bubble.contains("transcriptWidth: viewportWidth,"), bubble)
    }

    /// The stack's spacing is the style's one constant, and the row before is read only for a
    /// style with time lines: on the iPhone that read would be a fetch per row for nothing.
    ///
    /// Revert-check: `LazyVStack(spacing: 8)` makes the first assertion fail; reading
    /// `messageRow(atAbsoluteIndex: absoluteIndex - 1)` unconditionally makes the second fail.
    func testTranscript_spacingIsTheStylesAndThePreviousRowIsReadOnlyForTimeLines() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Views/Chat/ChatMessagesView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("LazyVStack(spacing: bubbleStyle.rowSpacing) {"))
        XCTAssertTrue(source.contains(
            "let previousMessage = bubbleStyle.showsTimestampSeparators\n"
                + "                        ? messageRow(atAbsoluteIndex: absoluteIndex - 1)\n"
                + "                        : nil\n"
        ))
        XCTAssertEqual(source.components(separatedBy: "messageRow(atAbsoluteIndex: absoluteIndex - 1)").count, 2)
    }

    /// The time line is drawn inside the row, by the bubble, so the transcript's `ForEach`
    /// still holds one view per message and its identities are what they were
    /// (`ChatTranscriptIdentityPolicy`).
    ///
    /// Revert-check: deleting the `ChatTranscriptRowLeadIn` modifier from `MessageBubble.body`
    /// makes the first assertion fail; drawing a `ChatTimestampSeparator` from
    /// `ChatMessagesView` makes the second fail.
    func testTimeLine_isDrawnByTheBubbleNotAsARowOfTheTranscript() throws {
        let bubble = try String(
            contentsOf: repoFile("esc-chatmail/Views/Chat/MessageBubble.swift"),
            encoding: .utf8
        )
        let transcript = try String(
            contentsOf: repoFile("esc-chatmail/Views/Chat/ChatMessagesView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(bubble.contains(".modifier(ChatTranscriptRowLeadIn(style: style, placement: runPlacement))"))
        XCTAssertFalse(transcript.contains("ChatTimestampSeparator("))
    }

    /// The arguments of the one call that opens with `opening` on a line of its own in a
    /// source file: from that line to the line that closes it at the call's own indentation.
    private func call(_ opening: String, in relativePath: String) throws -> String {
        let lines = try String(contentsOf: repoFile(relativePath), encoding: .utf8)
            .components(separatedBy: "\n")

        let openings = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespaces) == opening
        }
        XCTAssertEqual(openings.count, 1, "\(relativePath) no longer has exactly one \(opening)")
        let first = try XCTUnwrap(openings.first)
        let indentation = lines[first].prefix { $0 == " " }
        let closing = try XCTUnwrap(
            lines[(first + 1)...].firstIndex { $0 == indentation + ")" },
            "The \(opening) call in \(relativePath) has no closing line this test can find"
        )
        return lines[(first + 1)..<closing].joined(separator: "\n")
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
