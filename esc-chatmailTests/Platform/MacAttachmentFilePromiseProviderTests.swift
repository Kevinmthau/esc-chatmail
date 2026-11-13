#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import esc_chatmail

/// What a drag of an attachment out of a Mac chat carries (`MacAttachmentFilePromiseProvider`):
/// the promise's name, its type, and the copy that keeps it. Mac only, so it runs in
/// `Mac.xctestplan`; every file is in a temporary directory.
///
/// HONEST SCOPE: the provider's delegate methods are called directly, as AppKit calls them
/// when a promise is dropped. Nothing is dragged, so that the Finder asks for the promise,
/// uses the name it is given, and hands over a place the sandbox lets the app write to is not
/// pinned by anything, and has not been seen in the app.
final class MacAttachmentFilePromiseProviderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAttachmentFilePromiseProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func item(stored: String, filename: String, bytes: String?) throws -> AttachmentExportItem {
        let url = directory.appendingPathComponent(stored)
        if let bytes {
            try Data(bytes.utf8).write(to: url)
        }
        return AttachmentExportItem(sourceURL: url, filename: filename)
    }

    /// Keeps the promise as AppKit does, on the calling thread, and returns its one answer.
    private func write(_ provider: MacAttachmentFilePromiseProvider, to url: URL) -> Error? {
        var answers: [Error?] = []
        provider.filePromiseProvider(provider, writePromiseTo: url) { answers.append($0) }
        XCTAssertEqual(answers.count, 1, "The promise was not answered exactly once")
        return answers.first ?? nil
    }

    /// Revert-check: returning `item.sourceURL.lastPathComponent` from
    /// `filePromiseProvider(_:fileNameForType:)` makes this fail: the Finder would name the
    /// file for its storage identity, which is the reason the drag is a promise at all.
    func testPromise_isNamedAsASaveWouldNameIt_notAsTheFileOnDisk() throws {
        let provider = MacAttachmentFilePromiseProvider(
            item: try item(stored: "remote_0a1b2c.pdf", filename: "Q3 report.pdf", bytes: "x")
        )

        XCTAssertEqual(
            provider.filePromiseProvider(provider, fileNameForType: provider.fileType),
            "Q3 report.pdf"
        )
    }

    /// Revert-check: deleting `delegate = self` from `init(item:)` makes this fail. A provider
    /// with no delegate promises a file it never writes.
    func testProvider_isItsOwnDelegate() throws {
        let provider = MacAttachmentFilePromiseProvider(
            item: try item(stored: "remote_1.pdf", filename: "a.pdf", bytes: "x")
        )

        XCTAssertTrue(provider.delegate === provider)
    }

    /// Revert-check: announcing every promise as `UTType.data` makes the first three fail.
    func testFileType_followsTheNamesExtension_andIsDataWhereItSaysNothing() {
        XCTAssertEqual(MacAttachmentFilePromiseProvider.fileType(forFilename: "a.pdf"), UTType.pdf.identifier)
        XCTAssertEqual(MacAttachmentFilePromiseProvider.fileType(forFilename: "Beach.JPG"), UTType.jpeg.identifier)
        XCTAssertEqual(MacAttachmentFilePromiseProvider.fileType(forFilename: "a.tar.gz"), UTType.gzip.identifier)
        XCTAssertEqual(MacAttachmentFilePromiseProvider.fileType(forFilename: "notes"), UTType.data.identifier)
        XCTAssertEqual(MacAttachmentFilePromiseProvider.fileType(forFilename: "report v1.2 final"), UTType.data.identifier)

        let provider = MacAttachmentFilePromiseProvider(
            item: AttachmentExportItem(sourceURL: directory.appendingPathComponent("remote_1.png"), filename: "Logo.png")
        )
        XCTAssertEqual(provider.fileType, UTType.png.identifier)
    }

    /// Revert-check: answering the completion handler without calling
    /// `AttachmentFileExport.writePromise` makes this fail.
    func testKeepingThePromise_writesTheAttachmentsBytesWhereItWasAskedTo() throws {
        let provider = MacAttachmentFilePromiseProvider(
            item: try item(stored: "remote_1.pdf", filename: "Report.pdf", bytes: "report bytes")
        )
        let destination = directory.appendingPathComponent("dropped", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let url = destination.appendingPathComponent("Report.pdf")

        XCTAssertNil(write(provider, to: url))

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "report bytes")
    }

    /// A sign-out during the drag deletes the file.
    ///
    /// Revert-check: answering the completion handler with nil whatever the copy did makes
    /// this fail: the app it was dropped on would be told a file is there.
    func testKeepingThePromise_whenTheFileIsGone_answersWithTheError_andWritesNothing() throws {
        let provider = MacAttachmentFilePromiseProvider(
            item: try item(stored: "remote_gone.pdf", filename: "Report.pdf", bytes: nil)
        )
        let url = directory.appendingPathComponent("Report.pdf")

        let error = write(provider, to: url)

        XCTAssertEqual(
            error as? AttachmentFileExport.ExportError,
            .sourceMissing(filename: "Report.pdf")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Revert-check: returning `OperationQueue.main` from `operationQueue(for:)` makes this
    /// fail. The copy can be 25 MB onto another volume.
    func testThePromiseIsKeptOffTheMainThread() throws {
        let provider = MacAttachmentFilePromiseProvider(
            item: try item(stored: "remote_1.pdf", filename: "a.pdf", bytes: "x")
        )

        XCTAssertFalse(provider.operationQueue(for: provider) === OperationQueue.main)
    }
}
#endif
