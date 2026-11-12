import XCTest
@testable import esc_chatmail

/// Which composer each presenter gives its chat, and the wiring between the chat, the composer
/// and its one send that only source shows (`docs/mac-imessage-ui-plan.md`, PR 5).
///
/// `ChatView` takes its `ChatComposerStyle` as a required argument so each presenter names its
/// own. Naming the wrong one is not a compile error and no policy test would notice: the
/// iPhone's chat would lose its send button and raise no keyboard-sized bar, or the Mac's
/// would be the iPhone's bar, in which Return adds a line.
///
/// HONEST SCOPE: this reads source text, as `ChatHeaderStyleSourceTests` does, so it runs in
/// the iOS suite although some of the views are Mac-only. It pins what each call passes and
/// matches its spelling. What a style then decides is `ChatComposerPolicyTests`' to pin, and
/// the Mac's composer has not been seen in the app.
final class ChatComposerStyleSourceTests: XCTestCase {
    /// Revert-check: passing `composerStyle: .floating(.mac)` to the `ChatView` in
    /// `ConversationListView` makes this fail.
    func testIOSList_pushesItsChatWithTheBar() throws {
        let chat = try call("ChatView(", in: "esc-chatmail/Views/Main/ConversationListView.swift")

        XCTAssertTrue(chat.contains("composerStyle: .bar,"), chat)
    }

    /// Revert-check: passing `composerStyle: .bar` to the `ChatView` in `MacMailboxDetail`
    /// makes this fail.
    func testMacChatColumn_showsItsChatWithTheFloatingComposerAtTheMacsSizes() throws {
        let chat = try call("ChatView(", in: "esc-chatmail/Platform/MacMailboxDetail.swift")

        XCTAssertTrue(chat.contains("composerStyle: .floating(.mac),"), chat)
    }

    /// The style reaches the overlay and the reply bar in it.
    ///
    /// Revert-check: passing `style: .bar` at either call makes this fail.
    func testTranscript_handsTheComposerItsStyle() throws {
        let overlay = try call(
            "ChatReplyComposerOverlay(",
            in: "esc-chatmail/Views/Chat/ChatMessagesView.swift"
        )
        let bar = try call("ChatReplyBar(", in: "esc-chatmail/Views/Chat/ChatMessagesView.swift")

        XCTAssertTrue(overlay.contains("style: composerStyle"), overlay)
        XCTAssertTrue(bar.contains("style: style,"), bar)
    }

    /// The composer stays the overlay whose measured height is the transcript's bottom inset,
    /// in every style: the plan's "keep the structure, change the drawing". A `safeAreaBar`
    /// would take the composer out of that measurement, which the transcript's inset shifts
    /// and its anchor pass are built on.
    ///
    /// Revert-check: putting the composer in a `.safeAreaInset(edge: .bottom)` on the
    /// transcript makes the second assertion fail (a `safeAreaBar` makes the first fail the
    /// same way); deleting either `measuredHeight = ` write from `ChatReplyComposerOverlay`
    /// makes the third fail.
    func testComposer_staysAMeasuredOverlay_inEveryStyle() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Views/Chat/ChatMessagesView.swift"),
            encoding: .utf8
        )
        let overlayStart = try XCTUnwrap(source.range(of: "private struct ChatReplyComposerOverlay: View {"))
        let overlayEnd = try XCTUnwrap(
            source.range(of: "\n}\n", range: overlayStart.upperBound..<source.endIndex)
        )
        let overlay = String(source[overlayStart.lowerBound..<overlayEnd.upperBound])

        XCTAssertFalse(source.contains("safeAreaBar(edge: .bottom"))
        XCTAssertFalse(source.contains("safeAreaInset(edge: .bottom"))
        XCTAssertEqual(overlay.components(separatedBy: "measuredHeight = ").count, 3, overlay)
        // The divider and the opaque bar are the bar style's alone.
        XCTAssertTrue(overlay.contains(
            "            if backdrop == .dividerOverOpaqueBar {\n"
                + "                Divider()\n"
                + "            }\n"
        ))
        XCTAssertEqual(overlay.components(separatedBy: "Divider()").count, 2, overlay)
    }

    /// One send. The iPhone's button, the Mac's arrow and Return in the Mac's field all go
    /// through `sendIfAllowed`, which is the only caller of `onSend`, behind `canSend`. A
    /// second route to `onSend` would be a route around `canSend`.
    ///
    /// Revert-check: calling `Task { _ = await onSend() }` from the floating composer's
    /// `onSend:` argument makes the first assertion fail; deleting `if canSend` from
    /// `sendIfAllowed` makes the second fail.
    func testReplyBar_everySendGoesThroughTheOneGuardedFunction() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Views/Compose/ChatReplyBar.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(source.components(separatedBy: "await onSend()").count, 2)
        XCTAssertTrue(source.contains(
            "    private func sendIfAllowed() {\n"
                + "        if canSend {\n"
                + "            Task {\n"
                + "                _ = await onSend()\n"
                + "            }\n"
                + "        }\n"
                + "    }\n"
        ))
        XCTAssertTrue(source.contains("            onSend: sendIfAllowed,\n"))
        XCTAssertTrue(source.contains("        ) {\n            sendIfAllowed()\n        }\n"))
    }

    /// The Mac's field asks `canSend` of the text it holds, and Escape asks the policy.
    ///
    /// Revert-check: passing `canSend: { _ in true }` to `MacChatReplyBarLayout` makes the
    /// first assertion fail; calling `dropQuote()` from `onCancel:` without asking
    /// `ChatComposerPolicy.escapeDropsQuote` makes the second fail.
    func testFloatingComposer_asksCanSendOfTheFieldsText_andThePolicyAboutEscape() throws {
        let layout = try call(
            "MacChatReplyBarLayout(",
            in: "esc-chatmail/Views/Compose/ChatReplyBar.swift"
        )

        XCTAssertTrue(layout.contains("canSend: { canSend(replyText: $0) },"), layout)
        XCTAssertTrue(layout.contains(
            "            onCancel: {\n"
                + "                if ChatComposerPolicy.escapeDropsQuote(\n"
                + "                    header: header,\n"
                + "                    allowsDraftMutation: allowsDraftMutation\n"
                + "                ) {\n"
                + "                    dropQuote()\n"
                + "                }\n"
                + "            },\n"
        ), layout)
    }

    /// The chat asks the policy whether to focus its field as it appears, and reads and
    /// writes the focus only through `composerFocus`, so the Mac's field hears what the
    /// iPhone's does.
    ///
    /// Revert-check: deleting the `if ChatComposerPolicy.focusesFieldWhenChatAppears(` block
    /// from `ChatView`'s `onAppear` makes the first assertion fail; writing
    /// `isTextFieldFocused = false` anywhere in `ChatView` makes the second fail.
    func testChatView_asksThePolicyAboutFocus_andWritesItOnlyThroughComposerFocus() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Views/Chat/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "            if ChatComposerPolicy.focusesFieldWhenChatAppears(\n"
                + "                style: composerStyle,\n"
                + "                trigger: ChatAppearanceTrigger.current()\n"
                + "            ) {\n"
                + "                composerFocus.wrappedValue = true\n"
                + "            }\n"
        ))
        XCTAssertFalse(source.contains("isTextFieldFocused = "))
        XCTAssertTrue(source.contains("isTextFieldFocused: composerFocus,"))
    }

    // MARK: - Reading source

    /// The text of the first call to `name` in a source file, from its opening parenthesis to
    /// the one that closes it.
    private func call(_ name: String, in relativePath: String) throws -> String {
        let source = try String(contentsOf: repoFile(relativePath), encoding: .utf8)
        var searchStart = source.startIndex
        while let opening = source.range(of: name, range: searchStart..<source.endIndex) {
            searchStart = opening.upperBound
            // `MacChatView(` or `struct ChatReplyBar(` is some other text.
            if opening.lowerBound > source.startIndex {
                let before = source[source.index(before: opening.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" { continue }
            }
            var depth = 0
            var index = source.index(before: opening.upperBound)
            while index < source.endIndex {
                let character = source[index]
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        return String(source[opening.lowerBound...index])
                    }
                }
                index = source.index(after: index)
            }
        }
        XCTFail("\(relativePath) no longer has the \(name) call this test reads")
        throw CocoaError(.fileReadCorruptFile)
    }

    private func repoFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
