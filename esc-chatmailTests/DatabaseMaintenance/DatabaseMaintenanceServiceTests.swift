import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class DatabaseMaintenanceServiceTests: XCTestCase {
    // Revert-check: returning [] instead of nil on the failed ID fetch in
    // cleanupOrphanedHTMLFiles deletes this body through the real file handler.
    func testOrphanedHTMLCleanup_failedIDFetch_preservesStoredBody() async throws {
        let stack = TestCoreDataStack()
        let directory = makeMessagesDirectory()
        let handler = HTMLContentHandler(messagesDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        let bodyURL = try XCTUnwrap(handler.saveHTML("<p>keep</p>", for: "message"))

        await DatabaseMaintenanceService.cleanupOrphanedHTMLFiles(
            in: stack.viewContext,
            htmlContentHandler: handler,
            expectedGeneration: generation,
            fetchMessageIDs: { _ in
                throw CocoaError(.persistentStoreOperation)
            }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: bodyURL.path))
        XCTAssertEqual(handler.loadHTML(for: "message"), "<p>keep</p>")
    }

    // Revert-check: dropping expectedGeneration from the handler call (or
    // its accountBoundary.perform) deletes the replacement account's body.
    func testOrphanedHTMLCleanup_accountChangesDuringFetch_preservesReplacementBody() async throws {
        let stack = TestCoreDataStack()
        let directory = makeMessagesDirectory()
        let handler = HTMLContentHandler(messagesDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())

        await DatabaseMaintenanceService.cleanupOrphanedHTMLFiles(
            in: stack.viewContext,
            htmlContentHandler: handler,
            expectedGeneration: generation,
            fetchMessageIDs: { _ in
                handler.closeAccountWork()
                try handler.reopenAccountWork()
                XCTAssertNotNil(handler.saveHTML("<p>replacement account</p>", for: "replacement"))
                return []
            }
        )

        XCTAssertEqual(handler.loadHTML(for: "replacement"), "<p>replacement account</p>")
    }

    func testOrphanedHTMLCleanup_successfulIDFetch_removesOnlyOrphans() async throws {
        let stack = TestCoreDataStack()
        await stack.viewContext.perform {
            _ = MessageBuilder().withId("valid").build(in: stack.viewContext)
        }
        try stack.saveViewContext()
        let directory = makeMessagesDirectory()
        let handler = HTMLContentHandler(messagesDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        XCTAssertNotNil(handler.saveHTML("<p>valid</p>", for: "valid"))
        XCTAssertNotNil(handler.saveHTML("<p>orphan</p>", for: "orphan"))

        await DatabaseMaintenanceService.cleanupOrphanedHTMLFiles(
            in: stack.viewContext,
            htmlContentHandler: handler,
            expectedGeneration: generation
        )

        XCTAssertEqual(handler.loadHTML(for: "valid"), "<p>valid</p>")
        XCTAssertFalse(handler.htmlFileExists(for: "orphan"))
    }

    func testOrphanedHTMLCleanup_successfulEmptyIDFetch_removesOrphans() async throws {
        let stack = TestCoreDataStack()
        let directory = makeMessagesDirectory()
        let handler = HTMLContentHandler(messagesDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        XCTAssertNotNil(handler.saveHTML("<p>orphan</p>", for: "orphan"))

        await DatabaseMaintenanceService.cleanupOrphanedHTMLFiles(
            in: stack.viewContext,
            htmlContentHandler: handler,
            expectedGeneration: generation
        )

        XCTAssertFalse(handler.htmlFileExists(for: "orphan"))
    }

    private func makeMessagesDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseMaintenanceServiceTests-\(UUID().uuidString)", isDirectory: true)
    }
}
