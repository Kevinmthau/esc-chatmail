import XCTest
import CoreData
@testable import esc_chatmail

/// The removal of a deleted row's files, which runs some time after the delete: what it asks
/// before it unlinks (`DeletedRowFileReclamation`), and that it asks it for body files
/// (`HTMLContentHandler.deleteHTML(forDeleted:…)`) and attachment files
/// (`AttachmentCacheActor.deleteFiles(at:…)`) alike.
final class DeletedRowFileRemovalTests: XCTestCase {
    private var directory: URL!
    private var handler: HTMLContentHandler!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeletedRowFileRemoval-\(UUID().uuidString)", isDirectory: true)
        handler = HTMLContentHandler(messagesDirectory: directory)
    }

    override func tearDown() {
        try? handler.reopenAccountWork()
        try? FileManager.default.removeItem(at: directory)
        handler = nil
        directory = nil
        super.tearDown()
    }

    // MARK: - Body files

    func testDeletedBody_withNoStoredRow_isRemovedWithItsStoredLocation() throws {
        let elsewhere = directory.appendingPathComponent("elsewhere.html")
        XCTAssertNotNil(handler.saveHTML("<p>gone</p>", for: "gone"))
        try Data("<p>gone too</p>".utf8).write(to: elsewhere)
        let generation = try XCTUnwrap(handler.captureAccountGeneration())

        handler.deleteHTML(
            forDeleted: [DeletedMessageBody(messageId: "gone", bodyStorageURI: elsewhere.path)],
            deletedAt: Date(),
            expectedGeneration: generation,
            liveMessageIDs: { _ in [] }
        )

        XCTAssertFalse(handler.htmlFileExists(for: "gone"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    // Revert-check: the `liveMessageIDs` filter in `HTMLContentHandler.deleteHTML(forDeleted:…)`.
    // Unlink every body it is given, as `deleteHTML(for:bodyStorageURI:)` does, and the body
    // of the message that was stored again is gone.
    func testDeletedBody_whoseMessageIsStoredAgain_isLeft() throws {
        XCTAssertNotNil(handler.saveHTML("<p>restored</p>", for: "restored"))
        XCTAssertNotNil(handler.saveHTML("<p>gone</p>", for: "gone"))
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        let asked = LockedBox<[Set<String>]>([])

        handler.deleteHTML(
            forDeleted: [
                DeletedMessageBody(messageId: "restored", bodyStorageURI: nil),
                DeletedMessageBody(messageId: "gone", bodyStorageURI: nil)
            ],
            deletedAt: Date(),
            expectedGeneration: generation,
            liveMessageIDs: { ids in
                asked.update { $0.append(ids) }
                return ["restored"]
            }
        )

        XCTAssertEqual(asked.value, [["restored", "gone"]])
        XCTAssertEqual(handler.loadHTML(for: "restored"), "<p>restored</p>")
        XCTAssertFalse(handler.htmlFileExists(for: "gone"))
    }

    // Revert-check: `DeletedRowFileReclamation.wasWrittenAfter` in `removeDeletedBodyFile`.
    // Without it the body written after the delete is removed: its row is not saved yet,
    // so the stored-row check lets it through.
    func testDeletedBody_writtenAgainAfterTheDelete_isLeftEvenWithNoStoredRowYet() throws {
        let deletedAt = Date().addingTimeInterval(-60)
        XCTAssertNotNil(handler.saveHTML("<p>being stored again</p>", for: "returning"))
        let generation = try XCTUnwrap(handler.captureAccountGeneration())

        handler.deleteHTML(
            forDeleted: [DeletedMessageBody(messageId: "returning", bodyStorageURI: nil)],
            deletedAt: deletedAt,
            expectedGeneration: generation,
            liveMessageIDs: { _ in [] }
        )

        XCTAssertEqual(handler.loadHTML(for: "returning"), "<p>being stored again</p>")
    }

    // Revert-check: the `catch` in `HTMLContentHandler.deleteHTML(forDeleted:…)` that returns
    // without unlinking. Treat a failed read as "no rows" (`try?` and an empty set) and the
    // body is removed.
    func testDeletedBody_whenStoredRowsCannotBeRead_isLeft() throws {
        XCTAssertNotNil(handler.saveHTML("<p>unknown</p>", for: "unknown"))
        let generation = try XCTUnwrap(handler.captureAccountGeneration())

        handler.deleteHTML(
            forDeleted: [DeletedMessageBody(messageId: "unknown", bodyStorageURI: nil)],
            deletedAt: Date(),
            expectedGeneration: generation,
            liveMessageIDs: { _ in throw CocoaError(.persistentStoreTimeout) }
        )

        XCTAssertEqual(handler.loadHTML(for: "unknown"), "<p>unknown</p>")
    }

    // Revert-check: `expectedGeneration` on the `accountBoundary.perform` of each chunk. Pass
    // nil there and the next account's body, stored under the same ID, is removed.
    func testDeletedBody_fromAnAccountSinceClosedAndReopened_removesNothing() async throws {
        let staleGeneration = try XCTUnwrap(handler.captureAccountGeneration())
        handler.closeAccountWork()
        try await handler.deleteAllHTMLFromClosedAccount()
        try handler.reopenAccountWork()
        XCTAssertNotNil(handler.saveHTML("<p>new account</p>", for: "shared"))
        let lookups = LockedBox(0)

        handler.deleteHTML(
            forDeleted: [DeletedMessageBody(messageId: "shared", bodyStorageURI: nil)],
            deletedAt: Date(),
            expectedGeneration: staleGeneration,
            liveMessageIDs: { _ in
                lookups.update { $0 += 1 }
                return []
            }
        )

        XCTAssertEqual(handler.loadHTML(for: "shared"), "<p>new account</p>")
        XCTAssertEqual(lookups.value, 0, "A retired account's removal must not even ask the store")
    }

    // Revert-check: the `isCancelled()` guard before each chunk. Without it every chunk runs
    // and all five bodies are removed.
    func testDeletedBodies_areRemovedInChunks_andACancelledRemovalStopsBetweenThem() throws {
        let ids = (0..<5).map { "chunked-\($0)" }
        for id in ids {
            XCTAssertNotNil(handler.saveHTML("<p>\(id)</p>", for: id))
        }
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        let chunks = LockedBox<[Int]>([])

        handler.deleteHTML(
            forDeleted: ids.map { DeletedMessageBody(messageId: $0, bodyStorageURI: nil) },
            deletedAt: Date(),
            expectedGeneration: generation,
            chunkSize: 2,
            liveMessageIDs: { asked in
                chunks.update { $0.append(asked.count) }
                return []
            },
            isCancelled: { chunks.value.count >= 2 }
        )

        XCTAssertEqual(chunks.value, [2, 2])
        XCTAssertEqual(ids.map { handler.htmlFileExists(for: $0) }, [false, false, false, false, true])
    }

    // Revert-check: asking `liveMessageIDs` before `accountBoundary.perform` in
    // `HTMLContentHandler.deleteHTML(forDeleted:…)`. Ask it inside the perform again and the
    // other thread waits for the lock until the question is answered: the wait here times
    // out. That thread does what every context's save does in its notification
    // (`CacheCoordinator` captures the boundary's generation), and every body load.
    func testDeletedBodies_storeIsAskedWithoutTheBoundaryLockHeld() throws {
        XCTAssertNotNil(handler.saveHTML("<p>gone</p>", for: "gone"))
        let generation = try XCTUnwrap(handler.captureAccountGeneration())
        let handler = self.handler!
        let otherThreadGotTheLock = LockedBox<Bool?>(nil)

        handler.deleteHTML(
            forDeleted: [DeletedMessageBody(messageId: "gone", bodyStorageURI: nil)],
            deletedAt: Date(),
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

        XCTAssertEqual(otherThreadGotTheLock.value, true, "The store was asked with the boundary's lock held")
        XCTAssertFalse(handler.htmlFileExists(for: "gone"), "The answer is still used for the unlink")
    }

    // MARK: - Attachment files

    // Revert-check: the `DeletedRowFileReclamation.isRemovedWithItsRow` filter at the top of
    // `AttachmentCacheActor.deleteFiles(at:…)`. Without it the user's original and its
    // preview are removed with their row (no row names them, and they predate the delete),
    // and the store is asked about them.
    func testDeletedAttachmentFile_storedUnderALocalID_isLeftForTheOrphanSweep() async throws {
        AttachmentPaths.setupDirectories()
        let localID = "local_\(UUID().uuidString)"
        let original = AttachmentPaths.originalPath(idOrUUID: localID, ext: "jpg")
        let preview = AttachmentPaths.previewPath(idOrUUID: localID)
        XCTAssertTrue(AttachmentPaths.saveData(Data("mine".utf8), to: original))
        XCTAssertTrue(AttachmentPaths.saveData(Data("my preview".utf8), to: preview))
        let downloaded = try makeAttachmentFile(named: "downloaded")
        defer { [original, preview, downloaded].forEach { AttachmentPaths.deleteFile(at: $0) } }
        let cache = AttachmentCacheActor()
        let generation = try await unwrapped(cache.captureAccountGeneration())
        let asked = LockedBox<[[String]]>([])

        await cache.deleteFiles(
            at: [original, preview, downloaded],
            deletedAt: Date(),
            expectedAccountGeneration: generation,
            referencedPaths: { paths in
                asked.update { $0.append(paths) }
                return []
            }
        )

        XCTAssertNotNil(AttachmentPaths.loadData(from: original))
        XCTAssertNotNil(AttachmentPaths.loadData(from: preview))
        XCTAssertNil(AttachmentPaths.loadData(from: downloaded))
        XCTAssertEqual(asked.value, [[downloaded]])
    }

    func testIsRemovedWithItsRow_isFalseOnlyForAFileStoredUnderALocalID() {
        XCTAssertFalse(DeletedRowFileReclamation.isRemovedWithItsRow(
            AttachmentPaths.originalPath(idOrUUID: "local_1", ext: "jpg")
        ))
        XCTAssertFalse(DeletedRowFileReclamation.isRemovedWithItsRow(AttachmentPaths.previewPath(idOrUUID: "local_1")))
        XCTAssertTrue(DeletedRowFileReclamation.isRemovedWithItsRow(
            AttachmentPaths.originalPath(messageId: "m", attachmentId: "a", ext: "pdf")
        ))
        XCTAssertTrue(DeletedRowFileReclamation.isRemovedWithItsRow(
            AttachmentPaths.previewPath(messageId: "m", attachmentId: "a")
        ))
        // A legacy ID-only path of a Gmail attachment, which a sibling row can still name:
        // the stored-row check is what keeps that one.
        XCTAssertTrue(DeletedRowFileReclamation.isRemovedWithItsRow(
            AttachmentPaths.originalPath(idOrUUID: "ANGjdJ8w", ext: "pdf")
        ))
    }

    // Revert-check: the `referencedPaths` filter in `AttachmentCacheActor.deleteFileChunk`.
    // Unlink every path, as `deleteFile(at:)` does, and the file a sibling row still names
    // is gone.
    func testDeletedAttachmentFile_thatAStoredRowStillNames_isLeft() async throws {
        let shared = try makeAttachmentFile(named: "shared")
        let orphaned = try makeAttachmentFile(named: "orphaned")
        defer { [shared, orphaned].forEach { AttachmentPaths.deleteFile(at: $0) } }
        let cache = AttachmentCacheActor()
        let generation = try await unwrapped(cache.captureAccountGeneration())

        await cache.deleteFiles(
            at: [shared, orphaned],
            deletedAt: Date(),
            expectedAccountGeneration: generation,
            referencedPaths: { _ in [shared] }
        )

        XCTAssertNotNil(AttachmentPaths.loadData(from: shared))
        XCTAssertNil(AttachmentPaths.loadData(from: orphaned))
    }

    // Revert-check: `DeletedRowFileReclamation.wasWrittenAfter` in `deleteFileChunk`.
    func testDeletedAttachmentFile_writtenAgainAfterTheDelete_isLeft() async throws {
        let deletedAt = Date().addingTimeInterval(-60)
        let path = try makeAttachmentFile(named: "downloaded-again")
        defer { AttachmentPaths.deleteFile(at: path) }
        let cache = AttachmentCacheActor()
        let generation = try await unwrapped(cache.captureAccountGeneration())

        await cache.deleteFiles(
            at: [path],
            deletedAt: deletedAt,
            expectedAccountGeneration: generation,
            referencedPaths: { _ in [] }
        )

        XCTAssertNotNil(AttachmentPaths.loadData(from: path))
    }

    // Revert-check: the `catch` in `deleteFileChunk` that returns without unlinking.
    func testDeletedAttachmentFile_whenStoredRowsCannotBeRead_isLeft() async throws {
        let path = try makeAttachmentFile(named: "unknown")
        defer { AttachmentPaths.deleteFile(at: path) }
        let cache = AttachmentCacheActor()
        let generation = try await unwrapped(cache.captureAccountGeneration())

        await cache.deleteFiles(
            at: [path],
            deletedAt: Date(),
            expectedAccountGeneration: generation,
            referencedPaths: { _ in throw CocoaError(.persistentStoreTimeout) }
        )

        XCTAssertNotNil(AttachmentPaths.loadData(from: path))
    }

    // Revert-check: the `isAccountGenerationCurrent` guard that opens `deleteFileChunk`.
    func testDeletedAttachmentFile_fromAnAccountSinceClosedAndReopened_isLeft() async throws {
        let cache = AttachmentCacheActor()
        let staleGeneration = try await unwrapped(cache.captureAccountGeneration())
        await cache.closeAdmission()
        await cache.reopenAdmission()
        let path = try makeAttachmentFile(named: "new-account")
        defer { AttachmentPaths.deleteFile(at: path) }

        await cache.deleteFiles(
            at: [path],
            deletedAt: Date(),
            expectedAccountGeneration: staleGeneration,
            referencedPaths: { _ in [] }
        )

        XCTAssertNotNil(AttachmentPaths.loadData(from: path))
    }

    // MARK: - What the store is asked

    func testLiveMessageIDs_namesOnlyTheIDsWithASavedRow() throws {
        let stack = TestCoreDataStack()
        let writer = stack.newBackgroundContext()
        try writer.performAndWait {
            _ = MessageBuilder().withId("saved").build(in: writer)
            try writer.save()
            // Unsaved: a fresh context cannot see it, which is why a file written after the
            // delete is left by its date and not by this answer.
            _ = MessageBuilder().withId("unsaved").build(in: writer)
        }

        let live = try DeletedRowFileReclamation.liveMessageIDs(
            among: ["saved", "unsaved", "never-stored"],
            in: stack.newBackgroundContext()
        )

        XCTAssertEqual(live, ["saved"])
    }

    func testReferencedAttachmentPaths_namesAPathARowHoldsAsFileOrAsPreview() throws {
        let stack = TestCoreDataStack()
        let writer = stack.newBackgroundContext()
        try writer.performAndWait {
            _ = AttachmentBuilder()
                .withId("att-1")
                .withLocalURL("Attachments/kept.jpg")
                .withPreviewURL("Previews/kept.jpg")
                .build(in: writer)
            try writer.save()
        }

        let referenced = try DeletedRowFileReclamation.referencedAttachmentPaths(
            among: ["Attachments/kept.jpg", "Previews/kept.jpg", "Attachments/orphan.jpg"],
            in: stack.newBackgroundContext()
        )

        XCTAssertEqual(referenced, ["Attachments/kept.jpg", "Previews/kept.jpg"])
    }

    // MARK: - Helpers

    private func makeAttachmentFile(named name: String) throws -> String {
        AttachmentPaths.setupDirectories()
        let path = AttachmentPaths.originalPath(
            idOrUUID: "deleted-row-removal-\(name)-\(UUID().uuidString)",
            ext: "bin"
        )
        XCTAssertTrue(AttachmentPaths.saveData(Data(name.utf8), to: path))
        return path
    }

    private func unwrapped<T>(_ value: T?) throws -> T {
        try XCTUnwrap(value)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

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
