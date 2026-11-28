import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class DatabaseMaintenanceServiceTests: XCTestCase {
    // Revert-check: the `catch` in `HTMLContentHandler.cleanupOrphanedFiles` that returns
    // `.storeUnreadable`. Read a throwing chunk as "no rows" (`(try? …) ?? []`) and this body
    // is removed through the real file handler.
    func testOrphanedHTMLCleanup_failedIDFetch_preservesStoredBody() async throws {
        let stack = TestCoreDataStack()
        let directory = makeMessagesDirectory()
        let handler = HTMLContentHandler(messagesDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        let bodyURL = try XCTUnwrap(handler.saveHTML("<p>keep</p>", for: "message"))

        let outcome = await DatabaseMaintenanceService.cleanupOrphanedHTMLFiles(
            in: stack.viewContext,
            htmlContentHandler: handler,
            expectedGeneration: generation,
            fetchLiveMessageIDs: { _, _ in
                throw CocoaError(.persistentStoreOperation)
            }
        )

        XCTAssertEqual(outcome, .storeUnreadable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bodyURL.path))
        XCTAssertEqual(handler.loadHTML(for: "message"), "<p>keep</p>")
    }

    // Revert-check: `expectedGeneration` on the per-chunk `accountBoundary.perform` in
    // `HTMLContentHandler.cleanupOrphanedFiles`. Pass nil there and the replacement account's
    // body, stored under the listed name while the store was being asked, is removed. Its
    // date is set back, so the check of files written after the sweep began does not keep it.
    func testOrphanedHTMLCleanup_accountChangesDuringFetch_preservesReplacementBody() async throws {
        let stack = TestCoreDataStack()
        let directory = makeMessagesDirectory()
        let handler = HTMLContentHandler(messagesDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        XCTAssertNotNil(handler.saveHTML("<p>old account</p>", for: "shared"))

        let outcome = await DatabaseMaintenanceService.cleanupOrphanedHTMLFiles(
            in: stack.viewContext,
            htmlContentHandler: handler,
            expectedGeneration: generation,
            fetchLiveMessageIDs: { _, _ in
                handler.closeAccountWork()
                try handler.reopenAccountWork()
                let url = try XCTUnwrap(handler.saveHTML("<p>replacement account</p>", for: "shared"))
                try FileManager.default.setAttributes(
                    [.modificationDate: Date.distantPast],
                    ofItemAtPath: url.path
                )
                return []
            }
        )

        XCTAssertEqual(outcome, .accountChanged)
        XCTAssertEqual(handler.loadHTML(for: "shared"), "<p>replacement account</p>")
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

        let outcome = await DatabaseMaintenanceService.cleanupOrphanedHTMLFiles(
            in: stack.viewContext,
            htmlContentHandler: handler,
            expectedGeneration: generation
        )

        XCTAssertEqual(outcome, .completed)
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

        let outcome = await DatabaseMaintenanceService.cleanupOrphanedHTMLFiles(
            in: stack.viewContext,
            htmlContentHandler: handler,
            expectedGeneration: generation
        )

        XCTAssertEqual(outcome, .completed)
        XCTAssertFalse(handler.htmlFileExists(for: "orphan"))
    }

    /// The production fetch: `DeletedRowFileReclamation.liveMessageIDs` refuses a coordinator
    /// with no store as well, so this pins the default path end to end.
    func testOrphanedHTMLCleanup_noStoreAttached_defaultFetch_preservesStoredBody() async throws {
        let (container, _) = TestCoreDataStack.makeStorelessContainer()
        let directory = makeMessagesDirectory()
        let handler = HTMLContentHandler(messagesDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        let bodyURL = try XCTUnwrap(handler.saveHTML("<p>keep</p>", for: "message"))

        let outcome = await DatabaseMaintenanceService.cleanupOrphanedHTMLFiles(
            in: container.newBackgroundContext(),
            htmlContentHandler: handler,
            expectedGeneration: generation
        )

        XCTAssertEqual(outcome, .storeUnreadable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bodyURL.path))
        XCTAssertEqual(handler.loadHTML(for: "message"), "<p>keep</p>")
    }

    // Revert-check: the `CoreDataStack.requireAttachedStore(in:)` call in
    // `DatabaseMaintenanceService.cleanupOrphanedHTMLFiles`, outside the injectable fetch.
    // Without it this fetch, which checks nothing itself, answers [] on a coordinator with no
    // store and the stored body is removed.
    func testOrphanedHTMLCleanup_noStoreAttached_fetchThatChecksNothing_preservesStoredBody() async throws {
        let (container, _) = TestCoreDataStack.makeStorelessContainer()
        let directory = makeMessagesDirectory()
        let handler = HTMLContentHandler(messagesDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        let bodyURL = try XCTUnwrap(handler.saveHTML("<p>keep</p>", for: "message"))

        let outcome = await DatabaseMaintenanceService.cleanupOrphanedHTMLFiles(
            in: container.newBackgroundContext(),
            htmlContentHandler: handler,
            expectedGeneration: generation,
            fetchLiveMessageIDs: { _, _ in [] }
        )

        XCTAssertEqual(outcome, .storeUnreadable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bodyURL.path))
    }

    // Revert-check: `nonisolated` on `DatabaseMaintenanceService.cleanupOrphanedHTMLFiles`.
    // Without it the sweep is the main-actor class's, its listing and unlinks run on the
    // main thread, and the store question inside it (`performAndWait` runs its block on the
    // calling thread) is asked there too.
    func testOrphanedHTMLCleanup_asksTheStoreOffTheMainThread() async throws {
        let stack = TestCoreDataStack()
        let directory = makeMessagesDirectory()
        let handler = HTMLContentHandler(messagesDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        XCTAssertNotNil(handler.saveHTML("<p>orphan</p>", for: "orphan"))
        let askedOnMainThread = LockedFlags()

        let outcome = await DatabaseMaintenanceService.cleanupOrphanedHTMLFiles(
            in: stack.viewContext,
            htmlContentHandler: handler,
            expectedGeneration: generation,
            fetchLiveMessageIDs: { _, _ in
                askedOnMainThread.append(Thread.isMainThread)
                return []
            }
        )

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(askedOnMainThread.values, [false])
    }

    // HONEST SCOPE: nothing in the sweep can be removed to make this fail. It pins that the
    // run's cancellation reaches the sweep through the task that awaits it, which a sweep
    // moved into `Task.detached` (the review's warned-against way off the main actor) would
    // no longer see: it would remove the body.
    func testOrphanedHTMLCleanup_inACancelledTask_removesNothing() async throws {
        let stack = TestCoreDataStack()
        let directory = makeMessagesDirectory()
        let handler = HTMLContentHandler(messagesDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        XCTAssertNotNil(handler.saveHTML("<p>orphan</p>", for: "orphan"))
        let context = stack.viewContext

        let sweep = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return await DatabaseMaintenanceService.cleanupOrphanedHTMLFiles(
                in: context,
                htmlContentHandler: handler,
                expectedGeneration: generation,
                fetchLiveMessageIDs: { _, _ in [] }
            )
        }
        sweep.cancel()

        let outcome = await sweep.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(handler.loadHTML(for: "orphan"), "<p>orphan</p>")
    }

    func testOrphanedHTMLCleanup_withNoGeneration_sweepsNothing() async throws {
        let stack = TestCoreDataStack()
        let directory = makeMessagesDirectory()
        let handler = HTMLContentHandler(messagesDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNotNil(handler.saveHTML("<p>orphan</p>", for: "orphan"))

        let outcome = await DatabaseMaintenanceService.cleanupOrphanedHTMLFiles(
            in: stack.viewContext,
            htmlContentHandler: handler,
            expectedGeneration: nil,
            fetchLiveMessageIDs: { _, _ in [] }
        )

        XCTAssertEqual(outcome, .accountChanged)
        XCTAssertEqual(handler.loadHTML(for: "orphan"), "<p>orphan</p>")
    }

    private func makeMessagesDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseMaintenanceServiceTests-\(UUID().uuidString)", isDirectory: true)
    }
}

/// Values recorded from the sweep's thread, read back on the test's.
private final class LockedFlags: @unchecked Sendable {
    /// Guarded by `lock`.
    private var stored: [Bool] = []
    private let lock = NSLock()

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ value: Bool) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }
}
