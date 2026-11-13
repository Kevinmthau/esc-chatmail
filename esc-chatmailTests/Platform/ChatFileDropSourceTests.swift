import XCTest
@testable import esc_chatmail

/// The wiring that carries a file dropped on the Mac's chat to its reply's attachments, which
/// only source shows: the chat asks for drops, the composer's state holds the request, and
/// both of the reply bar's attachment pickers are handed it (`docs/mac-app-plan.md`, "Files").
///
/// HONEST SCOPE: this reads source text, as `ChatComposerStyleSourceTests` does, so it runs in
/// the iOS suite although the drop is the Mac's. It pins that each link of the chain is there
/// and matches its spelling. What each link does is `DraftFileDropPolicyTests`' and
/// `MacDraftFileDropViewTests`' to pin, and a drop has not been seen in the app.
final class ChatFileDropSourceTests: XCTestCase {
    /// Revert-check: deleting the `.macDraftFileDrop(` modifier from `ChatView` makes this
    /// fail. Without it nothing takes a file dropped on the chat, and the reply field and the
    /// email cards refuse the ones dropped on them.
    func testChat_takesFileDrops_andAsksItsComposersState() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Views/Chat/ChatView.swift"),
            encoding: .utf8
        )
        let modifier = try XCTUnwrap(source.range(of: "        .macDraftFileDrop(\n"))
        let end = try XCTUnwrap(source.range(of: "\n        )\n", range: modifier.upperBound..<source.endIndex))
        let call = String(source[modifier.lowerBound..<end.upperBound])

        XCTAssertTrue(call.contains("composerState.acceptsDroppedFiles"), call)
        XCTAssertTrue(call.contains("composerState.receiveDroppedFiles(urls)"), call)
        XCTAssertEqual(source.components(separatedBy: ".macDraftFileDrop(").count, 2)
    }

    /// Revert-check: deleting `fileDrop: $composerState.pendingFileDrop` from the
    /// `ChatReplyBar` in `ChatReplyComposerOverlay` makes this fail: a drop is taken and
    /// nothing imports it.
    func testComposerOverlay_handsTheReplyBarThePendingDrop() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Views/Chat/ChatMessagesView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "                recoveredReplyEnvelope: composerState.recoveredReplyEnvelope,\n"
                + "                fileDrop: $composerState.pendingFileDrop\n"
                + "            )\n"
        ))
    }

    /// The bar draws one of two pickers, the iPhone's buttons or the Mac's "+" menu, and each
    /// must be handed the drop: a picker without it never imports one.
    ///
    /// Revert-check: deleting `fileDrop: fileDrop` from either `AttachmentPicker` in
    /// `ChatReplyBar` makes this fail.
    func testReplyBar_handsBothOfItsPickersTheDrop() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Views/Compose/ChatReplyBar.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(source.components(separatedBy: "AttachmentPicker(").count, 3)
        XCTAssertEqual(source.components(separatedBy: "fileDrop: fileDrop\n").count, 3)
    }

    /// The picker takes a request once: it clears the request before it imports, so a view
    /// update between the two cannot start the import again.
    ///
    /// Revert-check: deleting `fileDrop.wrappedValue = nil` from the picker's `onChange`
    /// makes this fail.
    func testPicker_clearsTheRequestBeforeItImports() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Views/Components/AttachmentPicker.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "        .onChange(of: fileDrop.wrappedValue) { _, drop in\n"
                + "            guard let drop else { return }\n"
                + "            fileDrop.wrappedValue = nil\n"
                + "            importDroppedFiles(drop)\n"
                + "        }\n"
        ))
        // A dropped file has no security scope to open, so its import must not ask for one.
        XCTAssertTrue(source.contains("            securityScope: .ifOffered\n"))
    }

    private func repoFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
