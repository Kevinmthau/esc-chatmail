import XCTest
import CoreData
@testable import esc_chatmail

final class InlineCIDAttachmentPrefetcherTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
    }

    override func tearDown() {
        context = nil
        testStack = nil
        super.tearDown()
    }

    func testPrefetch_downloadsReferencedInlineAttachment() async throws {
        let message = MessageBuilder()
            .withId("message-inline-prefetch")
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId("att-inline-prefetch")
            .withFilename("logo.png")
            .withMimeType("image/png")
            .withContentId("Logo@Example.COM")
            .queued()
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let recorder = InlineCIDDownloadRecorder()
        let prefetcher = makePrefetcher(recorder: recorder)

        await prefetcher.prefetch(
            InlineCIDAttachmentPrefetchRequest(
                messageId: message.id,
                contentIDs: ["cid:logo@example.com"]
            )
        )

        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.messageId, message.id)
        XCTAssertEqual(calls.first?.objectURI, attachment.objectID.uriRepresentation().absoluteString)
    }

    func testPrefetch_doesNotRefetchAlreadyCachedInlineAttachment() async throws {
        AttachmentPaths.setupDirectories()
        let cachedPath = AttachmentPaths.originalPath(
            idOrUUID: "att-inline-cached-\(UUID().uuidString)",
            ext: "png"
        )
        XCTAssertTrue(AttachmentPaths.saveData(Data([0x01, 0x02, 0x03]), to: cachedPath))
        defer { AttachmentPaths.deleteFile(at: cachedPath) }

        let message = MessageBuilder()
            .withId("message-inline-prefetch-cached")
            .withAttachments()
            .build(in: context)
        AttachmentBuilder()
            .withId("att-inline-cached")
            .withFilename("logo.png")
            .withMimeType("image/png")
            .withContentId("logo@example.com")
            .downloaded()
            .withLocalURL(cachedPath)
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let recorder = InlineCIDDownloadRecorder()
        let prefetcher = makePrefetcher(recorder: recorder)

        await prefetcher.prefetch(
            InlineCIDAttachmentPrefetchRequest(
                messageId: message.id,
                contentIDs: ["logo@example.com"]
            )
        )

        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 0)
    }

    func testPrefetch_missingAttachmentMetadataFailsGracefully() async throws {
        let message = MessageBuilder()
            .withId("message-inline-prefetch-missing-metadata")
            .build(in: context)
        try testStack.saveViewContext()

        let recorder = InlineCIDDownloadRecorder()
        let prefetcher = makePrefetcher(recorder: recorder)

        await prefetcher.prefetch(
            InlineCIDAttachmentPrefetchRequest(
                messageId: message.id,
                contentIDs: ["missing@example.com"]
            )
        )

        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 0)
    }

    func testPrefetchDownloadFailureDoesNotRemoveMessageOrBlockDisplayFallback() async throws {
        let message = MessageBuilder()
            .withId("message-inline-prefetch-failure")
            .withAttachments()
            .build(in: context)
        AttachmentBuilder()
            .withId("att-inline-failure")
            .withFilename("logo.png")
            .withMimeType("image/png")
            .withContentId("failure@example.com")
            .queued()
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let recorder = InlineCIDDownloadRecorder()
        let prefetcher = makePrefetcher(recorder: recorder)

        await prefetcher.prefetch(
            InlineCIDAttachmentPrefetchRequest(
                messageId: message.id,
                contentIDs: ["failure@example.com"]
            )
        )

        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 1)
        let fetchedMessage = try XCTUnwrap(context.existingObject(with: message.objectID) as? Message)
        XCTAssertEqual(fetchedMessage.id, message.id)
    }

    func testPrefetch_retriesFailedAttachmentWhenFailureIsStale() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let message = MessageBuilder()
            .withId("message-inline-prefetch-stale-failure")
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId("att-inline-stale-failure")
            .withFilename("logo.png")
            .withMimeType("image/png")
            .withContentId("stale@example.com")
            .failed()
            .withLastDownloadFailedAt(now.addingTimeInterval(-3_600))
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let recorder = InlineCIDDownloadRecorder()
        let prefetcher = makePrefetcher(
            recorder: recorder,
            failedAttachmentRetryInterval: 300,
            now: { now }
        )

        await prefetcher.prefetch(
            InlineCIDAttachmentPrefetchRequest(
                messageId: message.id,
                contentIDs: ["stale@example.com"]
            )
        )

        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.messageId, message.id)
        XCTAssertEqual(calls.first?.objectURI, attachment.objectID.uriRepresentation().absoluteString)
    }

    func testPrefetch_skipsFailedAttachmentWhenFailureIsRecent() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let message = MessageBuilder()
            .withId("message-inline-prefetch-recent-failure")
            .withAttachments()
            .build(in: context)
        AttachmentBuilder()
            .withId("att-inline-recent-failure")
            .withFilename("logo.png")
            .withMimeType("image/png")
            .withContentId("recent@example.com")
            .failed()
            .withLastDownloadFailedAt(now.addingTimeInterval(-60))
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let recorder = InlineCIDDownloadRecorder()
        let prefetcher = makePrefetcher(
            recorder: recorder,
            failedAttachmentRetryInterval: 300,
            now: { now }
        )

        await prefetcher.prefetch(
            InlineCIDAttachmentPrefetchRequest(
                messageId: message.id,
                contentIDs: ["recent@example.com"]
            )
        )

        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 0)
    }

    func testPrefetch_successfulRetryClearsFailedAttachmentState() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let message = MessageBuilder()
            .withId("message-inline-prefetch-successful-retry")
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId("att-inline-successful-retry")
            .withFilename("logo.png")
            .withMimeType("image/png")
            .withContentId("retry@example.com")
            .failed()
            .withLastDownloadFailedAt(now.addingTimeInterval(-3_600))
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let attachmentObjectID = attachment.objectID
        let recorder = InlineCIDDownloadRecorder()
        let prefetcher = makePrefetcher(
            recorder: recorder,
            failedAttachmentRetryInterval: 300,
            now: { now },
            downloadAttachment: { objectID, messageId, context in
                await context.perform {
                    guard let attachment = try? context.existingObject(with: objectID) as? Attachment else {
                        return
                    }
                    attachment.state = .downloaded
                    attachment.lastDownloadFailedAt = nil
                    try? context.save()
                }
                await recorder.record(
                    messageId: messageId,
                    objectURI: objectID.uriRepresentation().absoluteString
                )
            }
        )

        await prefetcher.prefetch(
            InlineCIDAttachmentPrefetchRequest(
                messageId: message.id,
                contentIDs: ["retry@example.com"]
            )
        )

        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 1)

        let persistedState = try await fetchAttachmentState(objectID: attachmentObjectID)
        XCTAssertEqual(persistedState.state, .downloaded)
        XCTAssertNil(persistedState.lastDownloadFailedAt)
    }

    private func makePrefetcher(
        recorder: InlineCIDDownloadRecorder,
        failedAttachmentRetryInterval: TimeInterval = 30 * 60,
        now: @escaping @Sendable () -> Date = { Date() },
        downloadAttachment: InlineCIDAttachmentPrefetcher.AttachmentDownload? = nil
    ) -> InlineCIDAttachmentPrefetcher {
        let stack = testStack!
        let attachmentDownload = downloadAttachment ?? { objectID, messageId, _ in
            await recorder.record(
                messageId: messageId,
                objectURI: objectID.uriRepresentation().absoluteString
            )
        }

        return InlineCIDAttachmentPrefetcher(
            makeBackgroundContext: { stack.newBackgroundContext() },
            downloadAttachment: attachmentDownload,
            failedAttachmentRetryInterval: failedAttachmentRetryInterval,
            now: now
        )
    }

    private func fetchAttachmentState(
        objectID: NSManagedObjectID
    ) async throws -> (state: Attachment.State, lastDownloadFailedAt: Date?) {
        try await testStack.performBackgroundTask { context in
            guard let attachment = try context.existingObject(with: objectID) as? Attachment else {
                throw NSError(domain: "InlineCIDAttachmentPrefetcherTests", code: 1)
            }
            return (attachment.state, attachment.lastDownloadFailedAt)
        }
    }
}

private actor InlineCIDDownloadRecorder {
    private var recordedCalls: [(messageId: String, objectURI: String)] = []

    func record(messageId: String, objectURI: String) {
        recordedCalls.append((messageId, objectURI))
    }

    func calls() -> [(messageId: String, objectURI: String)] {
        recordedCalls
    }
}
