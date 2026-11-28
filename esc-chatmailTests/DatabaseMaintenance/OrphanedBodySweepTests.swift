import XCTest
@testable import esc_chatmail

/// The daily sweep of `Messages` for bodies no stored row names
/// (`HTMLContentHandler.cleanupOrphanedFiles`): chunked like the removal of deleted rows'
/// bodies, the store asked with the boundary's lock released, and stopped by cancellation,
/// an unreadable chunk or a change of account (architecture review 2026-11,
/// attachments-storage-disk#6).
final class OrphanedBodySweepTests: XCTestCase {
    private var directory: URL!
    private var handler: HTMLContentHandler!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrphanedBodySweep-\(UUID().uuidString)", isDirectory: true)
        handler = HTMLContentHandler(messagesDirectory: directory)
    }

    override func tearDown() {
        try? handler.reopenAccountWork()
        try? FileManager.default.removeItem(at: directory)
        handler = nil
        directory = nil
        super.tearDown()
    }

    func testSweep_removesOnlyTheBodiesNoStoredRowNames() throws {
        XCTAssertNotNil(handler.saveHTML("<p>stored</p>", for: "stored"))
        XCTAssertNotNil(handler.saveHTML("<p>orphan</p>", for: "orphan"))
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        let asked = LockedBox<[Set<String>]>([])

        let outcome = handler.cleanupOrphanedFiles(
            expectedGeneration: generation,
            liveMessageIDs: { ids in
                asked.update { $0.append(ids) }
                return ids.intersection(["stored"])
            }
        )

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(asked.value, [["stored", "orphan"]])
        XCTAssertEqual(handler.loadHTML(for: "stored"), "<p>stored</p>")
        XCTAssertFalse(handler.htmlFileExists(for: "orphan"))
    }

    func testSweep_ofAMissingDirectory_completesAndAsksNothing() throws {
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        try FileManager.default.removeItem(at: directory)
        let lookups = LockedBox(0)

        let outcome = handler.cleanupOrphanedFiles(
            expectedGeneration: generation,
            liveMessageIDs: { _ in
                lookups.update { $0 += 1 }
                return []
            }
        )

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(lookups.value, 0)
    }

    // Revert-check: the `isCancelled()` guard before each chunk. Without it every chunk runs,
    // all five bodies are removed and the sweep reports `.completed`.
    func testSweep_asksInChunks_andACancelledSweepStopsBetweenThem() throws {
        let ids = (0..<5).map { "chunked-\($0)" }
        for id in ids {
            XCTAssertNotNil(handler.saveHTML("<p>\(id)</p>", for: id))
        }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        let chunks = LockedBox<[Int]>([])

        let outcome = handler.cleanupOrphanedFiles(
            expectedGeneration: generation,
            chunkSize: 2,
            liveMessageIDs: { asked in
                chunks.update { $0.append(asked.count) }
                return []
            },
            isCancelled: { chunks.value.count >= 2 }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(chunks.value, [2, 2])
        // The listing's order is the file system's, so which body is left is not known.
        XCTAssertEqual(ids.filter { handler.htmlFileExists(for: $0) }.count, 1)
    }

    // Revert-check: asking `liveMessageIDs` before `accountBoundary.perform` in
    // `HTMLContentHandler.cleanupOrphanedFiles`. Ask it inside the perform and the other
    // thread waits for the lock until the question is answered: the wait here times out.
    // That thread does what every context's save does in its notification (`CacheCoordinator`
    // captures the boundary's generation), and every body load.
    func testSweep_asksTheStoreWithoutTheBoundaryLockHeld() throws {
        XCTAssertNotNil(handler.saveHTML("<p>orphan</p>", for: "orphan"))
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        let handler = self.handler!
        let otherThreadGotTheLock = LockedBox<Bool?>(nil)

        let outcome = handler.cleanupOrphanedFiles(
            expectedGeneration: generation,
            liveMessageIDs: { _ in
                let captured = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    _ = handler.captureAccountGeneration()
                    captured.signal()
                }
                let result = captured.wait(timeout: .now() + 2)
                otherThreadGotTheLock.update { $0 = result == .success }
                return []
            }
        )

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(otherThreadGotTheLock.value, true, "The store was asked with the boundary's lock held")
        XCTAssertFalse(handler.htmlFileExists(for: "orphan"), "The answer is still used for the unlink")
    }

    // Revert-check: the `return .storeUnreadable` in the sweep's `catch`. Go on to the next
    // chunk instead (`continue`, as the deleted-row removal does) and the second chunk's two
    // bodies are removed by a sweep that could not read the store.
    func testSweep_aChunkThatCannotBeRead_stopsTheSweepAndRemovesNothing() throws {
        let ids = (0..<4).map { "unreadable-\($0)" }
        for id in ids {
            XCTAssertNotNil(handler.saveHTML("<p>\(id)</p>", for: id))
        }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        let lookups = LockedBox(0)

        let outcome = handler.cleanupOrphanedFiles(
            expectedGeneration: generation,
            chunkSize: 2,
            liveMessageIDs: { _ in
                lookups.update { $0 += 1 }
                if lookups.value == 1 {
                    throw CocoaError(.persistentStoreTimeout)
                }
                return []
            }
        )

        XCTAssertEqual(outcome, .storeUnreadable)
        XCTAssertEqual(lookups.value, 1)
        XCTAssertEqual(ids.filter { handler.htmlFileExists(for: $0) }, ids)
    }

    // Revert-check: `expectedGeneration` on the per-chunk `accountBoundary.perform`. Pass nil
    // there and the first chunk's bodies, which now belong to the reopened account, are
    // removed. The sweep's start is put in the future so the check of files written since it
    // began keeps nothing here.
    func testSweep_accountReopenedWhileTheStoreIsAsked_removesNothing() throws {
        let ids = (0..<4).map { "reopened-\($0)" }
        for id in ids {
            XCTAssertNotNil(handler.saveHTML("<p>\(id)</p>", for: id))
        }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        let handler = self.handler!
        let lookups = LockedBox(0)

        let outcome = handler.cleanupOrphanedFiles(
            expectedGeneration: generation,
            startedAt: .distantFuture,
            chunkSize: 2,
            liveMessageIDs: { _ in
                lookups.update { $0 += 1 }
                handler.closeAccountWork()
                try handler.reopenAccountWork()
                return []
            }
        )

        XCTAssertEqual(outcome, .accountChanged)
        XCTAssertEqual(lookups.value, 1)
        XCTAssertEqual(ids.filter { handler.htmlFileExists(for: $0) }, ids)
    }

    // Revert-check: the `isAccountGenerationCurrent(expectedGeneration)` guard before each
    // chunk's question. Without it the store is asked about the second chunk for an account
    // that is no longer the caller's (the unlinks are still refused under the lock).
    func testSweep_accountReopenedBetweenChunks_asksTheStoreNoMore() throws {
        let ids = (0..<4).map { "between-\($0)" }
        for id in ids {
            XCTAssertNotNil(handler.saveHTML("<p>\(id)</p>", for: id))
        }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        let handler = self.handler!
        let lookups = LockedBox(0)
        let cancellationChecks = LockedBox(0)

        let outcome = handler.cleanupOrphanedFiles(
            expectedGeneration: generation,
            chunkSize: 2,
            liveMessageIDs: { _ in
                lookups.update { $0 += 1 }
                return []
            },
            isCancelled: {
                cancellationChecks.update { $0 += 1 }
                if cancellationChecks.value == 2 {
                    handler.closeAccountWork()
                    try? handler.reopenAccountWork()
                }
                return false
            }
        )

        XCTAssertEqual(outcome, .accountChanged)
        XCTAssertEqual(lookups.value, 1, "A retired account's sweep must not ask the store")
        XCTAssertEqual(ids.filter { handler.htmlFileExists(for: $0) }.count, 2)
    }

    // Revert-check: `DeletedRowFileReclamation.wasWrittenAfter(startedAt, …)` in the sweep's
    // unlink loop. Without it a body written after the sweep began, whose row may not be saved
    // yet, is removed because the store has no row for it.
    func testSweep_bodyWrittenAfterTheSweepBegan_isLeftEvenWithNoStoredRow() throws {
        let startedAt = Date().addingTimeInterval(-60)
        XCTAssertNotNil(handler.saveHTML("<p>being stored</p>", for: "arriving"))
        let generation = try XCTUnwrap(handler.captureAccountGeneration())

        let outcome = handler.cleanupOrphanedFiles(
            expectedGeneration: generation,
            startedAt: startedAt,
            liveMessageIDs: { _ in [] }
        )

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(handler.loadHTML(for: "arriving"), "<p>being stored</p>")
    }

    func testSweep_withAGenerationRetiredBeforeItBegins_asksAndRemovesNothing() throws {
        XCTAssertNotNil(handler.saveHTML("<p>kept</p>", for: "kept"))
        let staleGeneration = try XCTUnwrap(handler.captureAccountGeneration())
        handler.closeAccountWork()
        try handler.reopenAccountWork()
        let lookups = LockedBox(0)

        let outcome = handler.cleanupOrphanedFiles(
            expectedGeneration: staleGeneration,
            liveMessageIDs: { _ in
                lookups.update { $0 += 1 }
                return []
            }
        )

        XCTAssertEqual(outcome, .accountChanged)
        XCTAssertEqual(lookups.value, 0)
        XCTAssertEqual(handler.loadHTML(for: "kept"), "<p>kept</p>")
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    /// Guarded by `lock`.
    private var stored: Value
    private let lock = NSLock()

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&stored)
    }
}
