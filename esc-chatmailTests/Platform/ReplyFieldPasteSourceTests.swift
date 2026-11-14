import XCTest
@testable import esc_chatmail

/// The wiring of Paste in the Mac's reply field that only source shows: the two paste
/// commands ask about attachments first, the chat hands a pasted image's file on as a
/// temporary one, and the picker removes it when its import ends.
///
/// HONEST SCOPE: this reads source text, so it runs in the iOS suite and in CI although the
/// field is the Mac's, and it matches the spelling of the source. What each link does is
/// `ReplyFieldPastePolicyTests`', `PastedImageFileTests`' and `MacDraftFileDropViewTests`' to
/// pin. Nothing has been pasted in the app.
final class ReplyFieldPasteSourceTests: XCTestCase {
    /// The tests call `pasteAttachments` and never the commands, which read the user's own
    /// pasteboard where no other is given.
    ///
    /// Revert-check: deleting either override from `MacReplyTextView`, or calling `super`
    /// first in one, makes this fail: a copied file is pasted as its path again.
    func testBothPasteCommands_askAboutAttachmentsBeforeTheTextView() throws {
        let source = try source("esc-chatmail/Platform/MacReplyTextView.swift")

        XCTAssertTrue(source.contains(
            "    override func paste(_ sender: Any?) {\n"
                + "        if !pasteAttachments() {\n"
                + "            super.paste(sender)\n"
        ))
        XCTAssertTrue(source.contains(
            "    override func pasteAsPlainText(_ sender: Any?) {\n"
                + "        if !pasteAttachments() {\n"
                + "            super.pasteAsPlainText(sender)\n"
        ))
    }

    /// A text view enables Paste only for what it reads itself, which is no image.
    ///
    /// Revert-check: deleting the `validateUserInterfaceItem` override from
    /// `MacReplyTextView` makes this fail.
    func testPasteCommand_isValidatedByTheFieldBeforeTheTextView() throws {
        let source = try source("esc-chatmail/Platform/MacReplyTextView.swift")

        XCTAssertTrue(source.contains(
            "    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {\n"
                + "        enablesPasteItself(item) ? true : super.validateUserInterfaceItem(item)\n"
        ))
    }

    /// Revert-check: passing no `temporaryFileURLs` in `ChatView`'s `onPasteImageFile` makes
    /// this fail: a pasted image's file is never removed.
    func testChat_handsAPastedImagesFileOnAsATemporaryOne() throws {
        let source = try source("esc-chatmail/Views/Chat/ChatView.swift")

        XCTAssertTrue(source.contains(
            "            onPasteImageFile: { [composerState = viewModel.composerState] file in\n"
                + "                composerState.receiveDroppedFiles([file], temporaryFileURLs: [file])\n"
        ))
    }

    /// The import has its own copy by the time it ends, or has failed; either way the file
    /// was only for it.
    ///
    /// Revert-check: deleting the `if !isProcessing { PastedImageFile.remove(...) }` from
    /// `AttachmentPicker.importDroppedFiles` makes this fail.
    func testPicker_removesARequestsTemporaryFiles_whenItsImportEnds() throws {
        let source = try source("esc-chatmail/Views/Components/AttachmentPicker.swift")
        let start = try XCTUnwrap(source.range(of: "    private func importDroppedFiles(_ drop: DraftFileDrop) {"))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let function = String(source[start.lowerBound..<end.upperBound])

        XCTAssertTrue(function.contains(
            "                if !isProcessing {\n"
                + "                    PastedImageFile.remove(drop.temporaryFileURLs)\n"
        ), function)
    }

    /// A file whose import never ran, because its chat was closed first, has nothing left to
    /// remove it but a launch.
    ///
    /// Revert-check: deleting `PastedImageFile.removeAll()` from `esc_chatmailApp.init` makes
    /// this fail.
    func testApp_removesLeftoverPastedImagesAtLaunch_outsideTheTestHost() throws {
        let source = try source("esc-chatmail/App/esc_chatmailApp.swift")
        let guardRange = try XCTUnwrap(source.range(of: "        if !isRunningUnitTests {\n            SettingsAppAccountPublisher"))
        let sweep = try XCTUnwrap(source.range(of: "            PastedImageFile.removeAll()\n"))
        let close = try XCTUnwrap(source.range(of: "\n        }\n", range: guardRange.upperBound..<source.endIndex))

        XCTAssertLessThan(guardRange.lowerBound, sweep.lowerBound)
        XCTAssertLessThan(sweep.lowerBound, close.lowerBound)
    }

    private func source(_ relativePath: String) throws -> String {
        // This file is esc-chatmailTests/Platform/, so the repo root is three directories up.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
