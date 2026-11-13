import CoreData
import XCTest
@testable import esc_chatmail

/// Which attachments have a file a save can take, and under what name (`AttachmentExportItem`).
///
/// The attachments are rows of an in-memory store, and their files are in a temporary
/// directory that stands in for Application Support: the suite runs in the Mac plan, where the
/// test host's container is the real one.
@MainActor
final class AttachmentExportItemTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        stack = TestCoreDataStack()
        context = stack.makeMainQueueViewContext()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentExportItemTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Attachments", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Previews", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        context = nil
        stack = nil
        try await super.tearDown()
    }

    /// A stored relative path, in the temporary directory.
    private func resolve(_ relativePath: String?) -> URL? {
        relativePath.map { root.appendingPathComponent($0) }
    }

    private func item(for attachment: Attachment) -> AttachmentExportItem? {
        AttachmentExportItem(attachment: attachment, resolveURL: { self.resolve($0) })
    }

    private func write(_ relativePath: String) throws {
        try Data("bytes".utf8).write(to: root.appendingPathComponent(relativePath))
    }

    /// An attachment added on this device (`local_` IDs), whose path every reader may use.
    private func localAttachment(
        filename: String,
        localURL: String?,
        state: Attachment.State = .downloaded
    ) -> Attachment {
        let attachment = AttachmentBuilder()
            .withId("local_\(UUID().uuidString)")
            .withFilename(filename)
            .build(in: context)
        attachment.localURL = localURL
        attachment.state = state
        return attachment
    }

    /// Revert-check: building the name from `sourceURL.lastPathComponent` in place of the
    /// stored filename makes this fail. The file on disk is named for its storage identity.
    func testItem_forAnAttachmentWithItsFile_isThatFileUnderTheSendersName() throws {
        try write("Attachments/local_abc.pdf")
        let attachment = localAttachment(filename: "Q3 report.pdf", localURL: "Attachments/local_abc.pdf")

        let item = try XCTUnwrap(item(for: attachment))

        XCTAssertEqual(item.sourceURL, root.appendingPathComponent("Attachments/local_abc.pdf"))
        XCTAssertEqual(item.filename, "Q3 report.pdf")
    }

    /// Revert-check: passing the stored filename through unchanged makes this fail.
    func testItem_cleansTheSendersName_andGivesItTheFilesExtension() throws {
        try write("Attachments/local_abc.pdf")
        let attachment = localAttachment(filename: "../../.ssh/scan", localURL: "Attachments/local_abc.pdf")

        XCTAssertEqual(try XCTUnwrap(item(for: attachment)).filename, "scan.pdf")
    }

    /// Revert-check: deleting `attachment.isReady` from the initializer's guard makes this
    /// fail. A partial download can leave a file behind.
    func testItem_forAnAttachmentStillDownloading_isNil_evenWithAFileOnDisk() throws {
        try write("Attachments/local_abc.pdf")
        for state in [Attachment.State.queued, .failed, .uploading] {
            let attachment = localAttachment(filename: "a.pdf", localURL: "Attachments/local_abc.pdf", state: state)
            XCTAssertNil(item(for: attachment), "\(state)")
        }
    }

    func testItem_forAnAttachmentSentFromHere_isItsFile() throws {
        try write("Attachments/local_abc.jpg")
        let attachment = localAttachment(filename: "Beach.jpg", localURL: "Attachments/local_abc.jpg", state: .uploaded)

        XCTAssertEqual(try XCTUnwrap(item(for: attachment)).filename, "Beach.jpg")
    }

    /// Revert-check: deleting `fileExists(sourceURL)` from the initializer's guard makes this
    /// fail.
    func testItem_whenTheFileIsGone_isNil() {
        let attachment = localAttachment(filename: "a.pdf", localURL: "Attachments/local_gone.pdf")

        XCTAssertNil(item(for: attachment))
    }

    /// Quick Look shows the preview where the file is missing. A save must not: it would write
    /// a picture of a document's first page under the document's name.
    ///
    /// Revert-check: falling back to `readablePreviewURLValue` in the initializer, as
    /// `AttachmentPreviewItem.fileURL` does, makes this fail.
    func testItem_neverFallsBackToThePreview() throws {
        try write("Previews/local_abc.jpg")
        let attachment = localAttachment(filename: "Contract.pdf", localURL: "Attachments/local_gone.pdf")
        attachment.previewURL = "Previews/local_abc.jpg"

        XCTAssertNil(item(for: attachment))
    }

    /// A remote attachment's path must carry its message's identity: an ID-only legacy path
    /// can be a sibling message's file.
    ///
    /// Revert-check: reading `attachment.localURL` in place of `readableLocalURLValue` makes
    /// this fail.
    func testItem_forALegacyPathNoReaderMayUse_isNil_evenWithAFileOnDisk() throws {
        try write("Attachments/att-1.pdf")
        let attachment = AttachmentBuilder()
            .withId("att-1")
            .withFilename("a.pdf")
            .downloaded()
            .withLocalURL("Attachments/att-1.pdf")
            .build(in: context)

        XCTAssertNil(attachment.readableLocalURLValue)
        XCTAssertNil(item(for: attachment))
    }

    // MARK: - Save All

    /// Revert-check: appending to `missingFilenames` for every attachment without an item, in
    /// place of only the ready ones, makes this fail: a download in progress would be reported
    /// as a missing file.
    func testResolve_takesFilesThatAreThere_namesReadyOnesThatAreNot_andSkipsTheRest() throws {
        try write("Attachments/local_1.jpg")
        try write("Attachments/local_3.pdf")
        let attachments = [
            localAttachment(filename: "Beach.jpg", localURL: "Attachments/local_1.jpg"),
            localAttachment(filename: "Gone.pdf", localURL: "Attachments/local_gone.pdf"),
            localAttachment(filename: "Tickets.pdf", localURL: "Attachments/local_3.pdf", state: .uploaded),
            localAttachment(filename: "Loading.png", localURL: nil, state: .queued)
        ]

        let resolved = AttachmentExportItem.resolve(attachments) { self.item(for: $0) }

        XCTAssertEqual(resolved.items.map(\.filename), ["Beach.jpg", "Tickets.pdf"])
        XCTAssertEqual(resolved.missingFilenames, ["Gone.pdf"])
    }

    /// Sync can delete a message's rows while a menu that names them is open.
    ///
    /// Revert-check: deleting the `isLive` checks makes this fail, or reads a deleted row.
    func testADeletedAttachment_hasNoItem_andIsNotCounted() throws {
        try write("Attachments/local_1.jpg")
        let attachment = localAttachment(filename: "Beach.jpg", localURL: "Attachments/local_1.jpg")
        XCTAssertNotNil(item(for: attachment))
        context.delete(attachment)

        XCTAssertNil(item(for: attachment))
        XCTAssertEqual(AttachmentExportItem.displayFilename(of: attachment), "Attachment")
        let resolved = AttachmentExportItem.resolve([attachment]) { self.item(for: $0) }
        XCTAssertTrue(resolved.items.isEmpty)
        XCTAssertTrue(resolved.missingFilenames.isEmpty)
    }

    func testDisplayFilename_isTheCleanedName() {
        let attachment = localAttachment(filename: "dir/Report\u{202E}.pdf", localURL: nil, state: .queued)

        XCTAssertEqual(AttachmentExportItem.displayFilename(of: attachment), "Report.pdf")
    }
}
