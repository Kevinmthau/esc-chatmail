import XCTest
@testable import esc_chatmail

/// What a chat does with files dropped on it (`DraftFileDropPolicy`), and the composer state
/// that asks it (`ChatComposerState.receiveDroppedFiles`). The drop itself is the Mac's
/// (`MacDraftFileDropViewTests`); the decisions are plain values and run on both platforms.
@MainActor
final class DraftFileDropPolicyTests: XCTestCase {
    private let pdf = URL(fileURLWithPath: "/tmp/Report.pdf")
    private let photo = URL(fileURLWithPath: "/tmp/Photo.HEIC")
    private let archive = URL(fileURLWithPath: "/tmp/Everything.zip")

    // MARK: - Whether a drop is taken

    /// A compose sheet takes a drop where it offers the Files picker, which is New Message.
    ///
    /// Revert-check: dropping any one of the three terms from
    /// `DraftFileDropPolicy.composeSheetAllowsDrop` makes the assertion that turns only that
    /// term fail.
    func testComposeSheetAllowsDrop_onlyWithItsAttachmentControls_noSend_andNotDiscarded() {
        func allows(controls: Bool = true, sending: Bool = false, discarded: Bool = false) -> Bool {
            DraftFileDropPolicy.composeSheetAllowsDrop(
                showsAttachmentControls: controls,
                isSending: sending,
                hasDiscarded: discarded
            )
        }

        XCTAssertTrue(allows())
        XCTAssertFalse(allows(controls: false))
        XCTAssertFalse(allows(sending: true))
        XCTAssertFalse(allows(discarded: true))
    }

    /// Revert-check: dropping any one of the three terms from
    /// `DraftFileDropPolicy.acceptsFiles` makes the assertion that turns only that term fail.
    func testAcceptsFiles_onlyWhileNoSendNoImportAndNoEarlierDropOwnsTheDraft() {
        func accepts(mutation: Bool = true, processing: Bool = false, pending: Bool = false) -> Bool {
            DraftFileDropPolicy.acceptsFiles(
                allowsDraftMutation: mutation,
                isProcessingAttachments: processing,
                hasPendingDrop: pending
            )
        }

        XCTAssertTrue(accepts())
        XCTAssertFalse(accepts(mutation: false))
        XCTAssertFalse(accepts(processing: true))
        XCTAssertFalse(accepts(pending: true))
        XCTAssertFalse(accepts(mutation: false, processing: true, pending: true))
    }

    /// A drop that was taken is imported: at once, or when the import that is running ends.
    ///
    /// Revert-check: returning `hasPendingDrop` alone from `DraftFileDropPolicy.startsImport`
    /// makes the third assertion fail; returning `!isProcessingAttachments` alone makes the
    /// second fail.
    func testStartsImport_ofAPendingDrop_onlyWhileNoOtherImportRuns() {
        XCTAssertTrue(DraftFileDropPolicy.startsImport(hasPendingDrop: true, isProcessingAttachments: false))
        XCTAssertFalse(DraftFileDropPolicy.startsImport(hasPendingDrop: false, isProcessingAttachments: false))
        XCTAssertFalse(DraftFileDropPolicy.startsImport(hasPendingDrop: true, isProcessingAttachments: true))
        XCTAssertFalse(DraftFileDropPolicy.startsImport(hasPendingDrop: false, isProcessingAttachments: true))
    }

    /// Revert-check: dropping any one of the three terms from `DraftFileDropPolicy.takesDrag`
    /// makes the assertion that turns only that term fail.
    func testTakesDrag_onlyAFileDragThatMayBeCopied_whereAPasteWouldBeTaken() {
        func takes(files: Bool = true, copy: Bool = true, paste: Bool = true) -> Bool {
            DraftFileDropPolicy.takesDrag(carriesFiles: files, sourceAllowsCopy: copy, takesPaste: paste)
        }

        XCTAssertTrue(takes())
        XCTAssertFalse(takes(files: false))
        XCTAssertFalse(takes(copy: false))
        XCTAssertFalse(takes(paste: false))
    }

    /// A paste into the reply field is taken where a drop is. A sheet on the chat's window
    /// does not keep Command-V from the field behind it, so the sheet is asked about here.
    ///
    /// Revert-check: dropping either term from `DraftFileDropPolicy.takesPaste` makes the
    /// assertion that turns only that term fail.
    func testTakesPaste_onlyIntoAReplyThatCanTakeIt_withNoSheetUp() {
        XCTAssertTrue(DraftFileDropPolicy.takesPaste(windowHasSheet: false, acceptsFiles: true))
        XCTAssertFalse(DraftFileDropPolicy.takesPaste(windowHasSheet: true, acceptsFiles: true))
        XCTAssertFalse(DraftFileDropPolicy.takesPaste(windowHasSheet: false, acceptsFiles: false))
        XCTAssertFalse(DraftFileDropPolicy.takesPaste(windowHasSheet: true, acceptsFiles: false))
    }

    /// A second import would share the composer's one "processing" flag with the first, and
    /// the first to end would enable Send over the other's placeholder.
    ///
    /// Revert-check: dropping the `acceptsFiles` term from the guard in
    /// `DraftFileDropPolicy.decision` makes both fail.
    func testDecision_duringAnImport_refuses() {
        XCTAssertEqual(
            DraftFileDropPolicy.decision(droppedURLs: [pdf], allowsDraftMutation: true, isProcessingAttachments: true, hasPendingDrop: false),
            .refuse
        )
    }

    /// The composer holds one pending drop. A second would replace the first, whose files were
    /// taken from the user and would then never be attached.
    ///
    /// Revert-check: passing `hasPendingDrop: false` to `acceptsFiles` in
    /// `DraftFileDropPolicy.decision` whatever it was given makes this fail.
    func testDecision_whileAnEarlierDropWaitsForThePicker_refuses() {
        XCTAssertEqual(
            DraftFileDropPolicy.decision(
                droppedURLs: [pdf],
                allowsDraftMutation: true,
                isProcessingAttachments: false,
                hasPendingDrop: true
            ),
            .refuse
        )
    }

    func testDecision_duringASend_refuses() {
        XCTAssertEqual(
            DraftFileDropPolicy.decision(droppedURLs: [pdf], allowsDraftMutation: false, isProcessingAttachments: false, hasPendingDrop: false),
            .refuse
        )
    }

    /// Revert-check: dropping the `!files.isEmpty` term from the guard makes the first fail
    /// (it accepts a drop of nothing); deleting `.filter(\.isFileURL)` makes the second fail.
    func testDecision_withNoFiles_refuses() throws {
        let link = try XCTUnwrap(URL(string: "https://example.com/Report.pdf"))

        XCTAssertEqual(
            DraftFileDropPolicy.decision(droppedURLs: [], allowsDraftMutation: true, isProcessingAttachments: false, hasPendingDrop: false),
            .refuse
        )
        XCTAssertEqual(
            DraftFileDropPolicy.decision(droppedURLs: [link], allowsDraftMutation: true, isProcessingAttachments: false, hasPendingDrop: false),
            .refuse
        )
    }

    // MARK: - Which files it takes

    /// Revert-check: returning every file as supported from `decision` (dropping
    /// `.filter(isSupported)`) makes this fail, and so does naming none as unsupported.
    func testDecision_takesImagesAndPDFsInOrder_andNamesTheRest() {
        let decision = DraftFileDropPolicy.decision(
            droppedURLs: [photo, archive, pdf],
            allowsDraftMutation: true,
            isProcessingAttachments: false,
            hasPendingDrop: false
        )

        XCTAssertEqual(decision, .accept(fileURLs: [photo, pdf], unsupportedFilenames: ["Everything.zip"]))
    }

    /// Taken, so the alert can say why nothing was added: a refusal says nothing.
    ///
    /// Revert-check: refusing when no dropped file is supported makes this fail.
    func testDecision_withOnlyUnsupportedFiles_isStillTaken() {
        let decision = DraftFileDropPolicy.decision(
            droppedURLs: [archive],
            allowsDraftMutation: true,
            isProcessingAttachments: false,
            hasPendingDrop: false
        )

        XCTAssertEqual(decision, .accept(fileURLs: [], unsupportedFilenames: ["Everything.zip"]))
    }

    /// What the Files picker offers: images and PDFs (`DocumentAttachmentImporter.allowedContentTypes`).
    ///
    /// Revert-check: returning true from `isSupported` for a name it can make no type from
    /// (`guard let type … else { return true }`) makes the folder fail; checking against
    /// `[.pdf]` alone makes the images fail.
    func testIsSupported_isTheFilesPickersOffer() {
        for name in ["a.pdf", "a.PDF", "a.png", "a.jpg", "a.jpeg", "a.heic", "a.gif", "a.tiff", "a.webp"] {
            XCTAssertTrue(DraftFileDropPolicy.isSupported(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["a.zip", "a.txt", "a.docx", "a.mov", "a.app", "a.command", "a.qqqunknown", "Folder"] {
            XCTAssertFalse(DraftFileDropPolicy.isSupported(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    /// Revert-check: returning the bare filenames from `failures(forUnsupportedFilenames:)`
    /// makes this fail.
    func testFailures_sayWhatCanBeAttached() {
        XCTAssertEqual(
            DraftFileDropPolicy.failures(forUnsupportedFilenames: ["Everything.zip"]),
            ["Everything.zip can’t be attached. Only images and PDFs can be."]
        )
        XCTAssertEqual(DraftFileDropPolicy.failures(forUnsupportedFilenames: []), [])
    }

    // MARK: - The composer's state

    /// Revert-check: deleting the `pendingFileDrop = ` assignment from
    /// `ChatComposerState.receiveDroppedFiles` makes this fail.
    func testComposer_takesADrop_asAPendingRequestForThePicker() {
        let composer = ChatComposerState()

        XCTAssertTrue(composer.acceptsDroppedFiles)
        XCTAssertTrue(composer.receiveDroppedFiles([pdf, archive]))

        XCTAssertEqual(composer.pendingFileDrop?.fileURLs, [pdf])
        XCTAssertEqual(composer.pendingFileDrop?.unsupportedFilenames, ["Everything.zip"])
    }

    /// A pasted image's file is the app's own, written to carry the request, and goes with
    /// it so that whoever imports the request removes it. A dropped file is the user's and
    /// is never among them.
    ///
    /// Revert-check: dropping `temporaryFiles` from the `DraftFileDrop` made in
    /// `ChatComposerState.receiveDroppedFiles` makes the second assertion fail: the file
    /// stays in the temporary directory.
    func testComposer_takesPastedPicturesFiles_asTemporaryOnes_andADropAsNone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftFileDropPolicyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasted = try PastedImageFile.write(Data("one".utf8), fileExtension: "png", in: directory)
        let pasting = ChatComposerState()
        XCTAssertTrue(pasting.receivePastedImageFiles([pasted]))
        XCTAssertEqual(pasting.pendingFileDrop?.fileURLs, [pasted.url])
        XCTAssertEqual(pasting.pendingFileDrop?.temporaryFiles, [pasted])

        let dropping = ChatComposerState()
        XCTAssertTrue(dropping.receiveDroppedFiles([pdf]))
        XCTAssertEqual(dropping.pendingFileDrop?.temporaryFiles, [])
    }

    /// Until the picker has taken a drop the composer is the only holder of its files, so a
    /// second drop is refused, and slides back, in place of replacing the first.
    ///
    /// Revert-check: passing `hasPendingDrop: false` whatever the composer holds, in
    /// `acceptsDroppedFiles` and in `receiveDroppedFiles`, makes this fail: the second drop
    /// is taken and the first one's files are gone.
    func testComposer_withADropThePickerHasNotTaken_refusesAnother_andKeepsTheFirst() {
        let composer = ChatComposerState()
        XCTAssertTrue(composer.receiveDroppedFiles([pdf]))
        let first = composer.pendingFileDrop

        XCTAssertFalse(composer.acceptsDroppedFiles)
        XCTAssertFalse(composer.receiveDroppedFiles([photo]))

        XCTAssertEqual(composer.pendingFileDrop, first)
        XCTAssertEqual(composer.pendingFileDrop?.fileURLs, [pdf])
    }

    /// Two drops of the same files are two requests, so the picker's `onChange` sees both.
    func testComposer_twoDropsOfTheSameFile_areDifferentRequests() {
        let composer = ChatComposerState()

        XCTAssertTrue(composer.receiveDroppedFiles([pdf]))
        let first = composer.pendingFileDrop
        // The picker takes the first.
        composer.pendingFileDrop = nil
        XCTAssertTrue(composer.acceptsDroppedFiles)
        XCTAssertTrue(composer.receiveDroppedFiles([pdf]))

        XCTAssertNotNil(composer.pendingFileDrop)
        XCTAssertNotEqual(composer.pendingFileDrop, first)
    }

    /// Revert-check: passing `isProcessingAttachments: false` whatever the composer says, in
    /// `acceptsDroppedFiles` and in `receiveDroppedFiles`, makes this fail.
    func testComposer_duringAnImport_refusesADrop() {
        let composer = ChatComposerState()
        composer.isProcessingAttachments = true

        XCTAssertFalse(composer.acceptsDroppedFiles)
        XCTAssertFalse(composer.receiveDroppedFiles([pdf]))
        XCTAssertNil(composer.pendingFileDrop)
    }

    /// Revert-check: passing `allowsDraftMutation: true` whatever the composer says, in
    /// `acceptsDroppedFiles` and in `receiveDroppedFiles`, makes this fail.
    func testComposer_duringASend_refusesADrop() {
        let composer = ChatComposerState()
        XCTAssertTrue(composer.beginSending())

        XCTAssertFalse(composer.acceptsDroppedFiles)
        XCTAssertFalse(composer.receiveDroppedFiles([pdf]))
        XCTAssertNil(composer.pendingFileDrop)

        composer.finishSending()
        XCTAssertTrue(composer.acceptsDroppedFiles)
    }
}
