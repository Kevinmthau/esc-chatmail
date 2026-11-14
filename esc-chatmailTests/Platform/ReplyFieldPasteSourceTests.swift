import XCTest
@testable import esc_chatmail

/// The wiring of Paste in the Mac's reply field that only source shows: the two paste
/// commands ask the field first, the command is disabled behind a sheet before anything
/// else is asked of it, the chat hands pasted pictures' files on as temporary ones, and the
/// picker removes them when its import ends.
///
/// HONEST SCOPE: this reads source text, so it runs in the iOS suite and in CI although the
/// field is the Mac's, and it matches the spelling of the source. What each link does is
/// `ReplyFieldPastePolicyTests`', `PastedImageFileTests`' and `MacDraftFileDropViewTests`' to
/// pin. Nothing has been pasted in the app.
final class ReplyFieldPasteSourceTests: XCTestCase {
    /// The tests call `answerPaste` and never the commands, which read the user's own
    /// pasteboard where no other is given.
    ///
    /// Revert-check: deleting either override from `MacReplyTextView`, or calling `super`
    /// first in one, makes this fail: a copied file is pasted as its path again.
    func testBothPasteCommands_askTheFieldBeforeTheTextView() throws {
        let source = try source("esc-chatmail/Platform/MacReplyTextView.swift")

        XCTAssertTrue(source.contains(
            "    override func paste(_ sender: Any?) {\n"
                + "        if !answerPaste() {\n"
                + "            super.paste(sender)\n"
        ))
        XCTAssertTrue(source.contains(
            "    override func pasteAsPlainText(_ sender: Any?) {\n"
                + "        if !answerPaste() {\n"
                + "            super.pasteAsPlainText(sender)\n"
        ))
    }

    /// A text view enables Paste only for what it reads itself, which is no image, and it
    /// enables it behind a sheet as anywhere else. So the field answers first: no paste
    /// while its window has a sheet attached, then its own rule, then the text view's.
    ///
    /// Revert-check: deleting the `validateUserInterfaceItem` override from
    /// `MacReplyTextView` makes this fail, and so does deleting its
    /// `if disablesPaste(item) { return false }` or moving it below the other line: Paste
    /// is then enabled behind a sheet.
    func testPasteCommand_isValidatedByTheFieldBeforeTheTextView() throws {
        let source = try source("esc-chatmail/Platform/MacReplyTextView.swift")

        XCTAssertTrue(source.contains(
            "    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {\n"
                + "        if disablesPaste(item) { return false }\n"
                + "        return enablesPasteItself(item) ? true : super.validateUserInterfaceItem(item)\n"
        ))
    }

    /// Behind a sheet nothing is pasted, and that is asked before the pasteboard is: a
    /// paste that arrives there reads nothing of what was copied.
    ///
    /// Revert-check: moving the `fieldTakesPaste` guard below
    /// `let pasteboard = pasteboardForPaste()` in `MacReplyTextView.answerPaste` makes this
    /// fail.
    func testPaste_asksAboutASheet_beforeItAsksForThePasteboard() throws {
        let source = try source("esc-chatmail/Platform/MacReplyTextView.swift")
        let start = try XCTUnwrap(source.range(of: "    func answerPaste() -> Bool {\n"))
        let sheet = try XCTUnwrap(source.range(
            of: "        guard ReplyFieldPastePolicy.fieldTakesPaste(windowHasSheet: window?.attachedSheet != nil) else {\n",
            range: start.upperBound..<source.endIndex
        ))
        let pasteboard = try XCTUnwrap(source.range(
            of: "        let pasteboard = pasteboardForPaste()\n",
            range: start.upperBound..<source.endIndex
        ))

        XCTAssertLessThan(sheet.lowerBound, pasteboard.lowerBound)
    }

    /// The Edit menu is validated with no paste asked for, so the validation asks about the
    /// kinds the pasteboard has and reads nothing. What Paste would do can read the
    /// pasteboard's text, and is asked by a paste and nowhere else. CI runs no Mac test, so
    /// this is what CI has for it (`MacDraftFileDropViewTests` sees that nothing is read).
    ///
    /// Revert-check: asking `Self.pasteAction(for: pasteboardForPaste()) != .pasteAsText` in
    /// `MacReplyTextView.enablesPasteItself`, as it first did, makes the first two assertions
    /// fail.
    func testPasteValidation_asksAboutTheKindsAlone_andOnlyAPasteAsksWhatItWouldDo() throws {
        let source = try source("esc-chatmail/Platform/MacReplyTextView.swift")

        XCTAssertTrue(source.contains(
            "        let isPaste = Self.isPasteCommand(item)\n"
                + "        return isPaste && isEditable && Self.fieldEnablesPaste(for: pasteboardForPaste())\n"
        ))
        XCTAssertEqual(source.components(separatedBy: "Self.pasteAction(for: ").count - 1, 1)
        XCTAssertTrue(source.contains("        switch Self.pasteAction(for: pasteboard) {\n"))
    }

    /// Revert-check: handing the files on as dropped ones in `ChatView`'s
    /// `onPasteImageFiles` (`receiveDroppedFiles(files.map(\\.url))`), or passing no
    /// `temporaryFiles` in `ChatComposerState.receivePastedImageFiles`, makes this fail: a
    /// pasted image's file is never removed.
    func testChat_handsPastedPicturesFilesOnAsTemporaryOnes() throws {
        let chat = try source("esc-chatmail/Views/Chat/ChatView.swift")
        let composer = try source("esc-chatmail/ViewModels/ChatViewModel.swift")

        XCTAssertTrue(chat.contains(
            "            onPasteImageFiles: { [composerState = viewModel.composerState] files in\n"
                + "                composerState.receivePastedImageFiles(files)\n"
        ))
        XCTAssertTrue(composer.contains(
            "    func receivePastedImageFiles(_ files: [PastedImageFile]) -> Bool {\n"
                + "        receiveDroppedFiles(files.map(\\.url), temporaryFiles: files)\n"
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
                + "                    PastedImageFile.remove(drop.temporaryFiles)\n"
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
