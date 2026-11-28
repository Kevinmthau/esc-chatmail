import XCTest
import CoreData
@testable import esc_chatmail

/// A download on a disk with no room (architecture review 2026-11, attachments-storage-disk#5):
/// the free-space floor asked before anything is fetched (`AttachmentDownloadSpacePolicy`), and
/// a write that finds no room (`AttachmentWriteResult.outOfSpace`), which leave the row as it
/// was, `queued`, never failed and never retried.
///
/// Fixtures go through a main-queue context, as in `AttachmentDownloaderTests`; every test is
/// `@MainActor`.
final class AttachmentDownloaderDiskSpaceTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        viewContext = MainActor.assumeIsolated { testStack.makeMainQueueViewContext() }
        AttachmentPaths.setupDirectories()
    }

    override func tearDown() {
        viewContext = nil
        testStack = nil
        super.tearDown()
    }

    // MARK: - The free-space floor

    // Revert-check: the `hasRoomToDownload` guard before `apiClient.getAttachment` in
    // `AttachmentDownloader.performAttachmentDownload`. Without it the attachment is fetched
    // with one byte too few to keep the floor free.
    @MainActor
    func testDownload_thatWouldGoBelowTheFloor_fetchesNothingAndLeavesTheRowQueued() async throws {
        let fixture = try makeQueuedPNG(byteSize: 4_096)
        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses[fixture.responseKey] = fixture.png
        let downloader = makeDownloader(
            apiClient: apiClient,
            availableBytes: AttachmentDownloadSpacePolicy.floorBytes + 4_096 - 1
        )

        await downloader.downloadAttachment(
            attachmentObjectID: fixture.objectID,
            messageId: fixture.messageID,
            in: testStack.newBackgroundContext()
        )

        let row = try await fetchRow(fixture.objectID)
        XCTAssertEqual(apiClient.getAttachmentCallCountSnapshot(), 0)
        XCTAssertEqual(row.state, .queued)
        XCTAssertNil(row.lastDownloadFailedAt)
        XCTAssertNil(row.localURL)
        XCTAssertFalse(downloader.isDownloading(messageId: fixture.messageID, attachmentId: fixture.attachmentID))
    }

    @MainActor
    func testDownload_thatLeavesTheFloorFree_isDownloaded() async throws {
        let fixture = try makeQueuedPNG(byteSize: 4_096)
        defer { fixture.removeFiles() }
        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses[fixture.responseKey] = fixture.png
        let downloader = makeDownloader(
            apiClient: apiClient,
            availableBytes: AttachmentDownloadSpacePolicy.floorBytes + 4_096
        )

        await downloader.downloadAttachment(
            attachmentObjectID: fixture.objectID,
            messageId: fixture.messageID,
            in: testStack.newBackgroundContext()
        )

        let row = try await fetchRow(fixture.objectID)
        XCTAssertEqual(apiClient.getAttachmentCallCountSnapshot(), 1)
        XCTAssertEqual(row.state, .downloaded)
        XCTAssertEqual(row.localURL, fixture.originalPath)
    }

    @MainActor
    func testDownload_whenTheFreeSpaceCannotBeRead_isDownloaded() async throws {
        let fixture = try makeQueuedPNG(byteSize: 4_096)
        defer { fixture.removeFiles() }
        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses[fixture.responseKey] = fixture.png
        let downloader = makeDownloader(apiClient: apiClient, availableBytes: nil)

        await downloader.downloadAttachment(
            attachmentObjectID: fixture.objectID,
            messageId: fixture.messageID,
            in: testStack.newBackgroundContext()
        )

        XCTAssertEqual(apiClient.getAttachmentCallCountSnapshot(), 1)
        let row = try await fetchRow(fixture.objectID)
        XCTAssertEqual(row.state, .downloaded)
    }

    // Revert-check: the `hasRoomToDownload` guard in the `local_inline_` branch of
    // `AttachmentDownloader.performAttachmentDownload`. Without it the whole message is fetched
    // to recover the part, on a disk below the floor.
    @MainActor
    func testSynthesizedInlineRecovery_belowTheFloor_fetchesNoMessage() async throws {
        let messageID = "disk-space-inline-\(UUID().uuidString)"
        let recovered = makeSynthesizedInlineMessage(messageID: messageID, data: Data("inline bytes".utf8))
        let message = MessageBuilder().withId(messageID).withAttachments().build(in: viewContext)
        let attachment = AttachmentBuilder()
            .withId(recovered.attachmentID)
            .withFilename("inline.txt")
            .withMimeType("text/plain")
            .withByteSize(12)
            .queued()
            .forMessage(message)
            .build(in: viewContext)
        try saveViewContext()
        let apiClient = MockGmailAPIClient()
        apiClient.getMessageResponses[messageID] = recovered.message
        let downloader = makeDownloader(apiClient: apiClient, availableBytes: 0)

        await downloader.downloadAttachment(
            attachmentObjectID: attachment.objectID,
            messageId: messageID,
            in: testStack.newBackgroundContext()
        )

        XCTAssertEqual(apiClient.getMessageCallCountSnapshot(), 0)
        let row = try await fetchRow(attachment.objectID)
        XCTAssertEqual(row.state, .queued)
        XCTAssertNil(row.lastDownloadFailedAt)
    }

    // MARK: - A write that finds no room

    // Revert-check: the `if processedResult.outOfSpace` branch in
    // `AttachmentDownloader.performAttachmentDownload`. Without it the row is marked failed,
    // which the next showing downloads again.
    @MainActor
    func testDownload_whoseOriginalFindsNoRoom_isOneFetch_leavesTheRowQueuedAndNoFile() async throws {
        let fixture = try makeQueuedPNG(byteSize: 4_096)
        defer { fixture.removeFiles() }
        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses[fixture.responseKey] = fixture.png
        let downloader = makeDownloader(
            apiClient: apiClient,
            availableBytes: nil,
            writeAttachmentData: { _, _ in .outOfSpace }
        )

        await downloader.downloadAttachment(
            attachmentObjectID: fixture.objectID,
            messageId: fixture.messageID,
            in: testStack.newBackgroundContext()
        )

        let row = try await fetchRow(fixture.objectID)
        XCTAssertEqual(apiClient.getAttachmentCallCountSnapshot(), 1, "A full disk is not retried")
        XCTAssertEqual(row.state, .queued)
        XCTAssertNil(row.lastDownloadFailedAt)
        XCTAssertNil(row.localURL)
        XCTAssertFalse(fixture.originalExists)
    }

    // Revert-check: the `guard previewWrite != .outOfSpace` after the image preview's write in
    // `AttachmentDownloader.performAttachmentDownload`. Without it the original is kept and the
    // row ends downloaded with no preview, which `AttachmentThumbnailLoader.load` never draws.
    // The PNG is its own preview, so it is the preview's clone that finds no room.
    @MainActor
    func testDownload_whosePreviewFindsNoRoom_removesTheOriginalAndLeavesTheRowQueued() async throws {
        let fixture = try makeQueuedPNG(byteSize: 4_096)
        defer { fixture.removeFiles() }
        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses[fixture.responseKey] = fixture.png
        let previewPath = fixture.previewPath
        let downloader = makeDownloader(
            apiClient: apiClient,
            availableBytes: nil,
            writeAttachmentData: { data, path in
                path == previewPath ? .outOfSpace : AttachmentPaths.writeData(data, to: path)
            },
            storeAttachmentClone: { source, destination in
                destination == previewPath ? .outOfSpace : AttachmentPaths.storeClone(ofFileAt: source, at: destination)
            }
        )

        await downloader.downloadAttachment(
            attachmentObjectID: fixture.objectID,
            messageId: fixture.messageID,
            in: testStack.newBackgroundContext()
        )

        let row = try await fetchRow(fixture.objectID)
        XCTAssertEqual(row.state, .queued)
        XCTAssertNil(row.lastDownloadFailedAt)
        XCTAssertNil(row.localURL)
        XCTAssertFalse(fixture.originalExists)
    }

    @MainActor
    func testDownload_whoseWriteFailsOtherwise_marksTheRowFailed() async throws {
        let fixture = try makeQueuedPNG(byteSize: 4_096)
        defer { fixture.removeFiles() }
        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses[fixture.responseKey] = fixture.png
        let downloader = makeDownloader(
            apiClient: apiClient,
            availableBytes: nil,
            writeAttachmentData: { _, _ in .failed }
        )

        await downloader.downloadAttachment(
            attachmentObjectID: fixture.objectID,
            messageId: fixture.messageID,
            in: testStack.newBackgroundContext()
        )

        let row = try await fetchRow(fixture.objectID)
        XCTAssertEqual(row.state, .failed)
        XCTAssertNotNil(row.lastDownloadFailedAt)
    }

    // Revert-check: `!result.outOfSpace` on the failed write in
    // `SynthesizedInlineAttachmentRecovery.recover`'s persistence. Without it the requested row
    // is marked failed by a recovery that only found no room.
    @MainActor
    func testSynthesizedInlineRecovery_whoseWriteFindsNoRoom_leavesTheRowQueued() async throws {
        let messageID = "disk-space-inline-write-\(UUID().uuidString)"
        let recovered = makeSynthesizedInlineMessage(messageID: messageID, data: Data("inline bytes".utf8))
        let message = MessageBuilder().withId(messageID).withAttachments().build(in: viewContext)
        let attachment = AttachmentBuilder()
            .withId(recovered.attachmentID)
            .withFilename("inline.txt")
            .withMimeType("text/plain")
            .withByteSize(12)
            .queued()
            .forMessage(message)
            .build(in: viewContext)
        try saveViewContext()
        let apiClient = MockGmailAPIClient()
        apiClient.getMessageResponses[messageID] = recovered.message
        let downloader = makeDownloader(
            apiClient: apiClient,
            availableBytes: nil,
            writeAttachmentData: { _, _ in .outOfSpace }
        )

        await downloader.downloadAttachment(
            attachmentObjectID: attachment.objectID,
            messageId: messageID,
            in: testStack.newBackgroundContext()
        )

        XCTAssertEqual(apiClient.getMessageCallCountSnapshot(), 1)
        let row = try await fetchRow(attachment.objectID)
        XCTAssertEqual(row.state, .queued)
        XCTAssertNil(row.lastDownloadFailedAt)
        XCTAssertNil(row.localURL)
    }

    // MARK: - Helpers

    private struct QueuedPNG {
        let objectID: NSManagedObjectID
        let messageID: String
        let attachmentID: String
        let png: Data
        let originalPath: String
        let previewPath: String

        var responseKey: String { "\(messageID):\(attachmentID)" }

        var originalExists: Bool {
            AttachmentPaths.fullURL(for: originalPath).map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
        }

        func removeFiles() {
            AttachmentPaths.deleteFile(at: originalPath)
            AttachmentPaths.deleteFile(at: previewPath)
        }
    }

    /// A received PNG's row, `queued` with the byte size Gmail stated, and the PNG it downloads.
    @MainActor
    private func makeQueuedPNG(byteSize: Int64) throws -> QueuedPNG {
        let png = try TestImageData.encoded(as: .png, pixelSizes: [CGSize(width: 2, height: 2)])
        let messageID = "disk-space-message-\(UUID().uuidString)"
        let attachmentID = "disk-space-attachment-\(UUID().uuidString)"
        let message = MessageBuilder().withId(messageID).withAttachments().build(in: viewContext)
        let attachment = AttachmentBuilder()
            .withId(attachmentID)
            .withFilename("photo.png")
            .withMimeType("image/png")
            .withByteSize(byteSize)
            .queued()
            .forMessage(message)
            .build(in: viewContext)
        try saveViewContext()
        return QueuedPNG(
            objectID: attachment.objectID,
            messageID: messageID,
            attachmentID: attachmentID,
            png: png,
            originalPath: AttachmentPaths.originalPath(messageId: messageID, attachmentId: attachmentID, ext: "png"),
            previewPath: AttachmentPaths.previewPath(messageId: messageID, attachmentId: attachmentID)
        )
    }

    @MainActor
    private func makeDownloader(
        apiClient: MockGmailAPIClient,
        availableBytes: Int64?,
        writeAttachmentData: @escaping @Sendable (Data, String) -> AttachmentWriteResult = { data, path in
            AttachmentPaths.writeData(data, to: path)
        },
        storeAttachmentClone: @escaping @Sendable (String, String) -> AttachmentWriteResult = { source, destination in
            AttachmentPaths.storeClone(ofFileAt: source, at: destination)
        }
    ) -> AttachmentDownloader {
        AttachmentDownloader(
            apiClient: apiClient,
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            availableStorageBytes: { availableBytes },
            writeAttachmentData: writeAttachmentData,
            storeAttachmentClone: storeAttachmentClone
        )
    }

    private func fetchRow(
        _ objectID: NSManagedObjectID
    ) async throws -> (state: Attachment.State, lastDownloadFailedAt: Date?, localURL: String?) {
        try await testStack.performBackgroundTask { context in
            guard let attachment = try context.existingObject(with: objectID) as? Attachment else {
                throw NSError(domain: "AttachmentDownloaderDiskSpaceTests", code: 1)
            }
            return (attachment.state, attachment.lastDownloadFailedAt, attachment.localURL)
        }
    }

    @MainActor
    private func saveViewContext() throws {
        guard viewContext.hasChanges else { return }
        try viewContext.save()
    }

    /// A message whose one inline part is the synthesized `local_inline_` attachment the
    /// downloader recovers from the full message.
    private func makeSynthesizedInlineMessage(
        messageID: String,
        data: Data
    ) -> (attachmentID: String, message: GmailMessage) {
        let attachmentID = AttachmentPaths.synthesizedInlineAttachmentID(
            partId: "1.2",
            trimmedFilename: "inline.txt",
            mimeType: "text/plain",
            contentId: "inline@example.com",
            size: data.count
        )
        let encodedData = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let part = MessagePart(
            partId: "1.2",
            mimeType: "text/plain",
            filename: "inline.txt",
            headers: [
                MessageHeader(name: "Content-ID", value: "<inline@example.com>"),
                MessageHeader(name: "Content-Disposition", value: "inline")
            ],
            body: MessageBody(size: data.count, data: encodedData, attachmentId: nil),
            parts: nil
        )
        return (
            attachmentID,
            GmailMessage(
                id: messageID,
                threadId: "thread-\(messageID)",
                labelIds: ["INBOX"],
                snippet: nil,
                historyId: nil,
                internalDate: nil,
                payload: MessagePart(
                    partId: "",
                    mimeType: "multipart/related",
                    filename: nil,
                    headers: nil,
                    body: nil,
                    parts: [part]
                ),
                sizeEstimate: data.count
            )
        )
    }
}
