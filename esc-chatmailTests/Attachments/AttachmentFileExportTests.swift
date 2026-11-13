import XCTest
@testable import esc_chatmail

/// The copy behind Save Attachment… and Save All Attachments… (`AttachmentFileExport`), in a
/// temporary directory: it runs in the Mac plan too, where the test host's container is the
/// real one.
final class AttachmentFileExportTests: XCTestCase {
    private var directory: URL!
    private var sources: URL!
    private var destinationFolder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentFileExportTests-\(UUID().uuidString)", isDirectory: true)
        sources = directory.appendingPathComponent("sources", isDirectory: true)
        destinationFolder = directory.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func item(stored: String, filename: String, bytes: String) throws -> AttachmentExportItem {
        let url = sources.appendingPathComponent(stored)
        try Data(bytes.utf8).write(to: url)
        return AttachmentExportItem(sourceURL: url, filename: filename)
    }

    private func missingItem(filename: String) -> AttachmentExportItem {
        AttachmentExportItem(sourceURL: sources.appendingPathComponent("gone-\(UUID().uuidString).pdf"), filename: filename)
    }

    private func contents(of name: String) throws -> String {
        try String(contentsOf: destinationFolder.appendingPathComponent(name), encoding: .utf8)
    }

    private func savedNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: destinationFolder.path).sorted()
    }

    // MARK: - Save Attachment…

    /// Revert-check: deleting the `copyItem` call from `save` makes this fail.
    func testSave_copiesTheFile_andLeavesTheAppsCopy() throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "report bytes")
        let destination = destinationFolder.appendingPathComponent("Chosen name.pdf")

        try AttachmentFileExport.save(item, to: destination)

        XCTAssertEqual(try contents(of: "Chosen name.pdf"), "report bytes")
        XCTAssertEqual(try String(contentsOf: item.sourceURL, encoding: .utf8), "report bytes")
    }

    /// Revert-check: copying straight to `destination` when a file is already there makes this
    /// fail with a copy error. The save panel has already asked about replacing the file.
    func testSave_replacesAFileAlreadyThere() throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "new bytes")
        let destination = destinationFolder.appendingPathComponent("Report.pdf")
        try Data("old bytes".utf8).write(to: destination)

        try AttachmentFileExport.save(item, to: destination)

        XCTAssertEqual(try contents(of: "Report.pdf"), "new bytes")
    }

    /// Revert-check: deleting the `guard fileManager.fileExists(atPath: item.sourceURL.path)`
    /// from `save` makes this fail: the error is the system's copy error, with the wrong
    /// words for the user.
    func testSave_whenTheAttachmentsFileIsGone_reportsIt_andKeepsTheFileItWasToReplace() throws {
        let item = missingItem(filename: "Report.pdf")
        let destination = destinationFolder.appendingPathComponent("Report.pdf")
        try Data("old bytes".utf8).write(to: destination)

        XCTAssertThrowsError(try AttachmentFileExport.save(item, to: destination)) { error in
            XCTAssertEqual(
                error as? AttachmentFileExport.ExportError,
                .sourceMissing(filename: "Report.pdf")
            )
        }
        XCTAssertEqual(try contents(of: "Report.pdf"), "old bytes")
    }

    /// Found in review of PR 406: the file being replaced was removed before the copy, so a
    /// copy that failed (a full disk, a file a sign-out deleted meanwhile) left the user with
    /// neither.
    ///
    /// Revert-check: removing `destination` before the copy and copying straight to it makes
    /// this fail.
    func testSave_whenTheCopyFails_keepsTheFileItWasToReplace() throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "new bytes")
        let destination = destinationFolder.appendingPathComponent("Report.pdf")
        try Data("old bytes".utf8).write(to: destination)

        XCTAssertThrowsError(
            try AttachmentFileExport.save(item, to: destination, fileManager: CopyRefusingFileManager())
        ) { error in
            guard case .copyFailed(let filename, _)? = error as? AttachmentFileExport.ExportError else {
                return XCTFail("Expected a copy failure, got \(error)")
            }
            XCTAssertEqual(filename, "Report.pdf")
        }
        XCTAssertEqual(try contents(of: "Report.pdf"), "old bytes")
        XCTAssertEqual(try savedNames(), ["Report.pdf"])
    }

    func testSave_whenTheCopyFails_reportsTheChosenNameAndTheSystemsReason() throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "bytes")
        let destination = destinationFolder
            .appendingPathComponent("no such folder", isDirectory: true)
            .appendingPathComponent("Mine.pdf")

        XCTAssertThrowsError(try AttachmentFileExport.save(item, to: destination)) { error in
            guard case .copyFailed(let filename, let reason)? = error as? AttachmentFileExport.ExportError else {
                return XCTFail("Expected a copy failure, got \(error)")
            }
            XCTAssertEqual(filename, "Mine.pdf")
            XCTAssertFalse(reason.isEmpty)
        }
    }

    // MARK: - A dragged attachment

    /// Revert-check: deleting the `copyItem` call from `writePromise` makes this fail.
    func testWritePromise_copiesTheFileWhereItWasAskedTo() throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "report bytes")
        let destination = destinationFolder.appendingPathComponent("Report.pdf")

        try AttachmentFileExport.writePromise(item, to: destination)

        XCTAssertEqual(try contents(of: "Report.pdf"), "report bytes")
        XCTAssertEqual(try String(contentsOf: item.sourceURL, encoding: .utf8), "report bytes")
    }

    /// A drop asked no one about replacing anything.
    ///
    /// Revert-check: removing a file already at the destination before the copy, as `save`
    /// does, makes this fail.
    func testWritePromise_neverReplacesAFile() throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "new bytes")
        let destination = destinationFolder.appendingPathComponent("Report.pdf")
        try Data("the user's own".utf8).write(to: destination)

        XCTAssertThrowsError(try AttachmentFileExport.writePromise(item, to: destination)) { error in
            guard case .copyFailed(let filename, _)? = error as? AttachmentFileExport.ExportError else {
                return XCTFail("Expected a copy failure, got \(error)")
            }
            XCTAssertEqual(filename, "Report.pdf")
        }
        XCTAssertEqual(try contents(of: "Report.pdf"), "the user's own")
    }

    /// Revert-check: deleting the `guard fileManager.fileExists` from `writePromise` makes
    /// this fail: the error is the system's copy error, with the wrong words for the user.
    func testWritePromise_whenTheAttachmentsFileIsGone_saysSo() {
        let item = missingItem(filename: "Report.pdf")

        XCTAssertThrowsError(
            try AttachmentFileExport.writePromise(item, to: destinationFolder.appendingPathComponent("Report.pdf"))
        ) { error in
            XCTAssertEqual(error as? AttachmentFileExport.ExportError, .sourceMissing(filename: "Report.pdf"))
        }
        XCTAssertEqual(try? savedNames(), [])
    }

    // MARK: - Save All Attachments…

    func testSaveAll_savesEachFileUnderItsOwnName() throws {
        let items = [
            try item(stored: "remote_1.jpg", filename: "Beach.jpg", bytes: "one"),
            try item(stored: "remote_2.pdf", filename: "Tickets.pdf", bytes: "two")
        ]

        let failures = AttachmentFileExport.saveAll(items, into: destinationFolder)

        XCTAssertEqual(failures, [])
        XCTAssertEqual(try savedNames(), ["Beach.jpg", "Tickets.pdf"])
        XCTAssertEqual(try contents(of: "Beach.jpg"), "one")
        XCTAssertEqual(try contents(of: "Tickets.pdf"), "two")
    }

    /// Revert-check: copying to `item.filename` in place of the available name makes this
    /// fail: the second `image.jpg` is reported as a failed copy and the folder's own file
    /// stops the first. Photos from a phone are often all named alike.
    func testSaveAll_neverReplacesAFile_inTheFolderOrFromTheSameSave() throws {
        try Data("the user's own".utf8).write(to: destinationFolder.appendingPathComponent("image.jpg"))
        let items = [
            try item(stored: "remote_1.jpg", filename: "image.jpg", bytes: "first"),
            try item(stored: "remote_2.jpg", filename: "image.jpg", bytes: "second")
        ]

        let failures = AttachmentFileExport.saveAll(items, into: destinationFolder)

        XCTAssertEqual(failures, [])
        XCTAssertEqual(try savedNames(), ["image 2.jpg", "image 3.jpg", "image.jpg"])
        XCTAssertEqual(try contents(of: "image.jpg"), "the user's own")
        XCTAssertEqual(try contents(of: "image 2.jpg"), "first")
        XCTAssertEqual(try contents(of: "image 3.jpg"), "second")
    }

    /// Revert-check: returning at the first failure in `saveAll` makes this fail. One
    /// attachment that cannot be saved does not stop the ones after it.
    func testSaveAll_reportsWhatItCouldNotSave_andSavesTheRest() throws {
        let items = [
            try item(stored: "remote_1.jpg", filename: "Beach.jpg", bytes: "one"),
            missingItem(filename: "Gone.pdf"),
            try item(stored: "remote_3.pdf", filename: "Tickets.pdf", bytes: "three")
        ]

        let failures = AttachmentFileExport.saveAll(items, into: destinationFolder)

        XCTAssertEqual(failures, [.sourceMissing(filename: "Gone.pdf")])
        XCTAssertEqual(try savedNames(), ["Beach.jpg", "Tickets.pdf"])
    }

    func testSaveAll_intoAFolderThatIsGone_reportsEveryFile() throws {
        let items = [
            try item(stored: "remote_1.jpg", filename: "Beach.jpg", bytes: "one"),
            try item(stored: "remote_2.pdf", filename: "Tickets.pdf", bytes: "two")
        ]
        let gone = directory.appendingPathComponent("removed", isDirectory: true)

        let failures = AttachmentFileExport.saveAll(items, into: gone)

        XCTAssertEqual(failures.count, 2)
        for (failure, name) in zip(failures, ["Beach.jpg", "Tickets.pdf"]) {
            guard case .copyFailed(let filename, _) = failure else {
                return XCTFail("Expected a copy failure, got \(failure)")
            }
            XCTAssertEqual(filename, name)
        }
    }

    // MARK: - The alert's text

    func testFailureMessage_isOneLineForEachFile() {
        let message = AttachmentFileExport.failureMessage(for: [
            .sourceMissing(filename: "Gone.pdf"),
            .copyFailed(filename: "Beach.jpg", reason: "The disk is full.")
        ])

        XCTAssertEqual(
            message,
            "Gone.pdf is no longer on this Mac.\nBeach.jpg could not be saved. The disk is full."
        )
    }
}

/// A file manager whose copies fail, as on a full disk.
private final class CopyRefusingFileManager: FileManager {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteOutOfSpace)
    }
}
