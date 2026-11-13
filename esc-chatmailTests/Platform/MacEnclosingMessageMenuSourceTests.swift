import XCTest
@testable import esc_chatmail

/// That the transcript's row hands its menu entries down to the attachments inside it
/// (`View.macEnclosingMessageMenu`, `MacEnclosingMessageMenu`), which only source shows: an
/// attachment's own menu replaces the row's on the Mac, and ends with the row's entries only
/// where the row hands them down.
///
/// HONEST SCOPE: this reads source text, as `ChatFileDropSourceTests` does, so it runs in the
/// iOS suite although the menu is the Mac's. What the attachment's menu then holds is
/// `MacAttachmentExportMenuTests`' to pin, on a stand-in row. None of it has been seen in the
/// app.
final class MacEnclosingMessageMenuSourceTests: XCTestCase {
    /// Revert-check: deleting the `.macEnclosingMessageMenu` modifier from the row in
    /// `ChatMessagesView` makes this fail: a right-click on a message's attachment has no
    /// Reply and no Forward. Giving it other entries than the row's own menu makes it fail
    /// too.
    func testTranscriptRow_handsItsOwnMenuEntriesDown_besideItsMenu() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Views/Chat/ChatMessagesView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "                    .macEnclosingMessageMenu { messageContextMenu(for: message) }\n"
                + "                    .contextMenu { messageContextMenu(for: message) } preview: {\n"
        ))
    }

    /// Revert-check: returning `self` on the Mac too from `macEnclosingMessageMenu` makes
    /// this fail. On iOS the row is returned as it is, so its view tree is what it was.
    func testModifier_setsTheEnvironmentOnTheMac_andIsNothingOnIOS() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Platform/View+MacEnclosingMessageMenu.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "        #if os(macOS)\n"
                + "        environment(\\.macEnclosingMessageMenu, MacEnclosingMessageMenu { AnyView(entries()) })\n"
                + "        #else\n"
                + "        self\n"
                + "        #endif\n"
        ))
    }

    private func repoFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
