import XCTest
import SwiftUI
import CoreData
@testable import esc_chatmail

/// `DocumentAttachmentImporter` is the document import that used to live in `DocumentPicker`'s
/// coordinator, extracted so the Mac's `.fileImporter` shares it. These pin the callbacks its
/// owners rely on: processing turns on and back off, the operation is handed over for
/// cancellation and released, and failures are reported.
///
/// HONEST SCOPE: a successful import needs a security-scoped URL, which only a real document
/// picker hands out (`startAccessingSecurityScopedResource` refuses a plain file URL), so the
/// happy path is not covered here.
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

    private func makeImporter(registry: AttachmentAccountWorkRegistry) -> DocumentAttachmentImporter {
        DocumentAttachmentImporter(
            attachments: Binding(
                get: { self.attachments },
                set: { self.attachments = $0 }
            ),
            viewContext: context,
            onProcessingChanged: { self.processingChanges.append($0) },
            onOperationChanged: { self.operationChanges.append($0) },
            onImportFailures: { self.reportedFailures.append($0) },
            registry: registry
        )
    }

    private func missingFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentAttachmentImporterTests-\(UUID().uuidString).pdf")
    }
}
