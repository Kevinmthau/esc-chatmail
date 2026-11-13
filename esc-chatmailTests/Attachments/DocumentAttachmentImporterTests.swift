import XCTest
import SwiftUI
import CoreData
@testable import esc_chatmail

/// `DocumentAttachmentImporter` is the document import that used to live in `DocumentPicker`'s
/// coordinator, extracted so the Mac's `.fileImporter` shares it. These pin the callbacks its
/// owners rely on: processing turns on and back off, the operation is handed over for
/// cancellation and released, and failures are reported.
///
/// HONEST SCOPE: these run on the iOS simulator, where `startAccessingSecurityScopedResource`
/// answers true for any file that exists. So a real file imports here whatever the importer
/// asks of its scope, and the difference between a picker's file and a dropped one
/// (`SecurityScope`) cannot be seen: the rule is pinned as a table below, and the Mac's
/// sandbox, where a dropped file opens no scope, in `MacDraftFileDropViewTests`.
@MainActor
final class DocumentAttachmentImporterTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var attachments: [Attachment] = []
    private var processingChanges: [Bool] = []
    private var operationChanges: [Task<Void, Never>?] = []
    private var reportedFailures: [[String]] = []

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.makeMainQueueViewContext()
        attachments = []
        processingChanges = []
        operationChanges = []
        reportedFailures = []
    }

    override func tearDown() {
        attachments = []
        operationChanges = []
        context = nil
        stack = nil
        super.tearDown()
    }

    /// With account admission closed (mid sign-out) nothing starts, and processing turns back
    /// off at once rather than leaving the composer's import spinner stuck.
    ///
    /// Revert-check: removing `onProcessingChanged(false)` from the refused branch of
    /// `DocumentAttachmentImporter.importDocuments(at:)` makes this fail.
    func testImportDocuments_admissionClosed_startsNothingAndEndsProcessing() {
        let registry = AttachmentAccountWorkRegistry(admissionOpen: false)

        makeImporter(registry: registry).importDocuments(at: [missingFileURL()])

        XCTAssertEqual(processingChanges, [true, false])
        XCTAssertEqual(operationChanges.count, 1)
        XCTAssertNil(operationChanges.first ?? nil)
        XCTAssertTrue(reportedFailures.isEmpty)
        XCTAssertEqual(registry.activeOperationCount, 0)
    }

    /// A file that cannot be read is reported by name, leaves no placeholder behind, and ends
    /// processing and the operation.
    ///
    /// Revert-check: removing the `onProcessingChanged(false)` / `onOperationChanged(nil)` pair
    /// at the end of the registered operation in `DocumentAttachmentImporter.importDocuments(at:)`
    /// makes this fail; so does removing `await onImportFailures(failures)` from
    /// `processDocuments`.
    func testImportDocuments_unreadableFile_reportsFailureAndEndsProcessing() async throws {
        let registry = AttachmentAccountWorkRegistry()
        let url = missingFileURL()

        makeImporter(registry: registry).importDocuments(at: [url])

        XCTAssertEqual(processingChanges, [true])
        let operation = try XCTUnwrap(operationChanges.first ?? nil)
        await operation.value

        XCTAssertEqual(processingChanges, [true, false])
        XCTAssertEqual(operationChanges.count, 2)
        XCTAssertNil(operationChanges.last ?? nil)
        XCTAssertEqual(reportedFailures.count, 1)
        XCTAssertEqual(reportedFailures.first?.count, 1)
        XCTAssertTrue(
            reportedFailures.first?.first?.contains(url.lastPathComponent) == true,
            "the failure names the file"
        )
        XCTAssertTrue(attachments.isEmpty)
    }

    func testAllowedContentTypes_arePDFsAndImages() {
        XCTAssertEqual(
            DocumentAttachmentImporter.allowedContentTypes,
            [.pdf, .image, .jpeg, .png, .heic]
        )
    }

    // MARK: - A file dropped on a chat (no security scope)

    /// Revert-check: answering `didStartAccessing` for `.ifOffered` too makes the second
    /// assertion fail; answering true for `.required` makes the fourth fail.
    func testSecurityScope_aPickersFileNeedsItsScope_aDroppedFileDoesNot() {
        XCTAssertTrue(DocumentAttachmentImporter.SecurityScope.ifOffered.allowsReading(didStartAccessing: true))
        XCTAssertTrue(DocumentAttachmentImporter.SecurityScope.ifOffered.allowsReading(didStartAccessing: false))
        XCTAssertTrue(DocumentAttachmentImporter.SecurityScope.required.allowsReading(didStartAccessing: true))
        XCTAssertFalse(DocumentAttachmentImporter.SecurityScope.required.allowsReading(didStartAccessing: false))
    }

    /// A real file imports in full, as a dropped file does: the placeholder is finalized
    /// with the file's bytes on disk.
    ///
    /// HONEST SCOPE: the simulator opens a scope for this file, so `.required` imports it
    /// too. This covers the import a drop starts, not the scope rule.
    ///
    /// Revert-check: deleting the `attachment.localURL = originalPath` assignment from
    /// `processDocuments` makes this fail.
    func testImportDocuments_aRealFile_isFinalizedWithItsBytesOnDisk() async throws {
        let registry = AttachmentAccountWorkRegistry()
        let url = try plainFile(named: "Dropped.pdf", bytes: Data("%PDF-1.4 not really".utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        makeImporter(registry: registry, securityScope: .ifOffered).importDocuments(at: [url])
        let operation = try XCTUnwrap(operationChanges.first ?? nil)
        await operation.value

        XCTAssertEqual(reportedFailures, [])
        XCTAssertEqual(processingChanges, [true, false])
        let attachment = try XCTUnwrap(attachments.first)
        defer {
            AttachmentPaths.deleteFile(at: attachment.localURL)
            AttachmentPaths.deleteFile(at: attachment.previewURL)
        }
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachment.filename, "Dropped.pdf")
        XCTAssertEqual(attachment.mimeType, "application/pdf")
        XCTAssertEqual(attachment.byteSize, 19)
        let saved = try XCTUnwrap(AttachmentPaths.fullURL(for: attachment.localURL))
        XCTAssertEqual(try Data(contentsOf: saved), Data("%PDF-1.4 not really".utf8))
    }

    /// The pickers ask for a scope unless told otherwise.
    ///
    /// Revert-check: making `.ifOffered` the default of
    /// `DocumentAttachmentImporter.securityScope` makes this fail.
    func testSecurityScope_isRequiredByDefault() {
        let importer = DocumentAttachmentImporter(
            attachments: .constant([]),
            viewContext: context,
            onProcessingChanged: { _ in },
            onOperationChanged: { _ in },
            onImportFailures: { _ in }
        )

        XCTAssertEqual(importer.securityScope, .required)
    }

    /// A real file in a directory of its own, reached by a plain file URL.
    private func plainFile(named name: String, bytes: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentAttachmentImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func makeImporter(
        registry: AttachmentAccountWorkRegistry,
        securityScope: DocumentAttachmentImporter.SecurityScope = .required
    ) -> DocumentAttachmentImporter {
        DocumentAttachmentImporter(
            attachments: Binding(
                get: { self.attachments },
                set: { self.attachments = $0 }
            ),
            viewContext: context,
            onProcessingChanged: { self.processingChanges.append($0) },
            onOperationChanged: { self.operationChanges.append($0) },
            onImportFailures: { self.reportedFailures.append($0) },
            registry: registry,
            securityScope: securityScope
        )
    }

    private func missingFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentAttachmentImporterTests-\(UUID().uuidString).pdf")
    }
}
