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

    private func makePrefetcher(recorder: InlineCIDDownloadRecorder) -> InlineCIDAttachmentPrefetcher {
        let stack = testStack!
        return InlineCIDAttachmentPrefetcher(
            makeBackgroundContext: { stack.newBackgroundContext() },
            downloadAttachment: { objectID, messageId, _ in
                await recorder.record(
                    messageId: messageId,
                    objectURI: objectID.uriRepresentation().absoluteString
                )
            }
        )
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
