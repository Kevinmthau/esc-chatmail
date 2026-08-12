import XCTest
import CoreData
@testable import esc_chatmail

/// Tests for AttachmentDownloader infrastructure and state management.
///
/// Note: Full integration tests with actual download behavior require network mocking.
/// These tests focus on:
/// - Attachment state transitions
/// - Core Data entity handling
/// - Cleanup logic validation
final class AttachmentDownloaderTests: XCTestCase {

    var testStack: TestCoreDataStack!
    var context: NSManagedObjectContext!

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

    // MARK: - AttachmentBuilder Tests

    func testAttachmentBuilder_createsBasicAttachment() throws {
        let attachment = AttachmentBuilder()
            .withId("att-123")
            .withFilename("test.txt")
            .withMimeType("text/plain")
            .queued()
            .build(in: context)

        XCTAssertEqual(attachment.id, "att-123")
        XCTAssertEqual(attachment.filename, "test.txt")
        XCTAssertEqual(attachment.mimeType, "text/plain")
        XCTAssertEqual(attachment.state, .queued)
    }

    func testAttachmentBuilder_createsImageAttachment() throws {
        let attachment = AttachmentBuilder()
            .asImage(width: 1920, height: 1080)
            .downloaded()
            .withLocalURL("Attachments/photo.jpg")
            .withPreviewURL("Previews/photo.jpg")
            .build(in: context)

        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertEqual(attachment.width, 1920)
        XCTAssertEqual(attachment.height, 1080)
        XCTAssertEqual(attachment.state, .downloaded)
        XCTAssertEqual(attachment.localURL, "Attachments/photo.jpg")
        XCTAssertEqual(attachment.previewURL, "Previews/photo.jpg")
    }

    func testAttachmentBuilder_createsPDFAttachment() throws {
        let attachment = AttachmentBuilder()
            .asPDF(pageCount: 5)
            .downloaded()
            .build(in: context)

        XCTAssertEqual(attachment.mimeType, "application/pdf")
        XCTAssertEqual(attachment.pageCount, 5)
        XCTAssertEqual(attachment.state, .downloaded)
    }

    func testAttachmentBuilder_linksToMessage() throws {
        let message = MessageBuilder()
            .withId("msg-123")
            .withSubject("Test with attachment")
            .build(in: context)

        let attachment = AttachmentBuilder()
            .withId("att-456")
            .forMessage(message)
            .build(in: context)

        XCTAssertEqual(attachment.message?.id, "msg-123")
    }

    // MARK: - State Transition Tests

    func testAttachmentState_transitionsFromQueuedToDownloaded() throws {
        let attachment = AttachmentBuilder()
            .queued()
            .build(in: context)

        XCTAssertEqual(attachment.state, .queued)

        attachment.state = .downloaded
        XCTAssertEqual(attachment.state, .downloaded)

        try testStack.saveViewContext()

        // Verify persistence
        let fetchedAttachment = try context.existingObject(with: attachment.objectID) as? Attachment
        XCTAssertEqual(fetchedAttachment?.state, .downloaded)
    }

    func testAttachmentState_transitionsFromQueuedToFailed() throws {
        let attachment = AttachmentBuilder()
            .queued()
            .build(in: context)

        XCTAssertEqual(attachment.state, .queued)

        attachment.state = .failed
        XCTAssertEqual(attachment.state, .failed)

        try testStack.saveViewContext()

        let fetchedAttachment = try context.existingObject(with: attachment.objectID) as? Attachment
        XCTAssertEqual(fetchedAttachment?.state, .failed)
    }

    func testAttachmentState_transitionsFromFailedToQueued() throws {
        // Simulates retry scenario
        let attachment = AttachmentBuilder()
            .failed()
            .build(in: context)

        XCTAssertEqual(attachment.state, .failed)

        // Reset for retry
        attachment.state = .queued
        XCTAssertEqual(attachment.state, .queued)
    }

    @MainActor
    func testDownloadFailureAfterRetryBudgetMarksFailedAndCleansInFlight() async throws {
        let message = MessageBuilder()
            .withId("message-download-retry-failure")
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId("att-download-retry-failure")
            .withFilename("missing.png")
            .withMimeType("image/png")
            .queued()
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let apiClient = MockGmailAPIClient()
        let downloader = AttachmentDownloader(
            apiClient: apiClient,
            maxRetryAttempts: 2,
            baseRetryDelay: 0
        )
        let backgroundContext = testStack.newBackgroundContext()
        let beforeDownload = Date()

        await downloader.downloadAttachment(
            attachmentObjectID: attachment.objectID,
            messageId: message.id,
            in: backgroundContext
        )

        let persistedState = try await fetchAttachmentState(objectID: attachment.objectID)
        XCTAssertEqual(apiClient.getAttachmentCallCount, 2)
        XCTAssertEqual(persistedState.state, .failed)
        let failedAt = try XCTUnwrap(persistedState.lastDownloadFailedAt)
        XCTAssertGreaterThanOrEqual(failedAt, beforeDownload)
        XCTAssertFalse(
            downloader.isDownloading(
                messageId: message.id,
                attachmentId: attachment.id
            )
        )
        XCTAssertNil(
            downloader.downloadProgress(
                messageId: message.id,
                attachmentId: attachment.id
            )
        )
    }

    @MainActor
    func testCancelAndAwaitAllDownloadsWaitsForSuspendedAutomaticRequestAndPreventsSuccessWrite() async throws {
        let message = MessageBuilder()
            .withId("message-cancelled-automatic-download")
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId("att-cancelled-automatic-download")
            .withFilename("cancelled.txt")
            .withMimeType("text/plain")
            .queued()
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let request = SuspendedAttachmentRequest(outcome: .success(Data("old account".utf8)))
        let apiClient = MockGmailAPIClient()
        apiClient.getAttachmentOperation = { _, _ in
            try await request.perform()
        }
        let downloader = AttachmentDownloader(
            apiClient: apiClient,
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        )

        downloader.schedulePendingAttachmentDownloads()
        await request.waitUntilStarted()
        XCTAssertTrue(
            downloader.isDownloading(
                messageId: message.id,
                attachmentId: attachment.id
            )
        )

        let cleanupFinished = AttachmentCleanupFlag()
        let cleanupTask = Task { @MainActor in
            await downloader.cancelAndAwaitAllDownloads()
            cleanupFinished.set()
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertFalse(
            cleanupFinished.isSet,
            "Cleanup must await even an attachment request that ignores task cancellation"
        )
        XCTAssertTrue(
            downloader.isDownloading(
                messageId: message.id,
                attachmentId: attachment.id
            )
        )

        await request.release()
        await cleanupTask.value

        let persistedState = try await fetchAttachmentState(objectID: attachment.objectID)
        XCTAssertEqual(apiClient.getAttachmentCallCountSnapshot(), 1)
        XCTAssertEqual(persistedState.state, .queued)
        XCTAssertNil(persistedState.lastDownloadFailedAt)
        XCTAssertNil(persistedState.localURL)
        XCTAssertNil(persistedState.previewURL)
        XCTAssertFalse(
            downloader.isDownloading(
                messageId: message.id,
                attachmentId: attachment.id
            )
        )
        XCTAssertNil(
            downloader.downloadProgress(
                messageId: message.id,
                attachmentId: attachment.id
            )
        )
    }

    @MainActor
    func testCancelAndAwaitAllDownloadsDrainsManualRequestWithoutRetryOrFailureWrite() async throws {
        let message = MessageBuilder()
            .withId("message-cancelled-automatic-retry")
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId("att-cancelled-automatic-retry")
            .withFilename("cancelled.dat")
            .withMimeType("application/octet-stream")
            .queued()
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let request = SuspendedAttachmentRequest(outcome: .failure)
        let apiClient = MockGmailAPIClient()
        apiClient.getAttachmentOperation = { _, _ in
            try await request.perform()
        }
        let downloader = AttachmentDownloader(
            apiClient: apiClient,
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            maxRetryAttempts: 3,
            baseRetryDelay: 0
        )

        let manualDownloadTask = Task { @MainActor in
            await downloader.downloadAttachmentIfNeeded(for: attachment)
        }
        await request.waitUntilStarted()
        let cleanupFinished = AttachmentCleanupFlag()
        let cleanupTask = Task { @MainActor in
            await downloader.cancelAndAwaitAllDownloads()
            cleanupFinished.set()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(
            cleanupFinished.isSet,
            "Teardown must drain a manual writer it does not own as a Task"
        )
        await request.release()
        await cleanupTask.value
        await manualDownloadTask.value

        let persistedState = try await fetchAttachmentState(objectID: attachment.objectID)
        XCTAssertEqual(apiClient.getAttachmentCallCountSnapshot(), 1)
        XCTAssertEqual(persistedState.state, .queued)
        XCTAssertNil(persistedState.lastDownloadFailedAt)
        XCTAssertNil(persistedState.localURL)
        XCTAssertNil(persistedState.previewURL)
        let observedCancellation = await request.observedCancellation
        XCTAssertTrue(
            observedCancellation,
            "Teardown must cancel the downloader-owned task running the manual/CID operation"
        )
    }

    @MainActor
    func testCancelAndAwaitAllDownloadsDrainsCIDReadAfterDownloadPersistence() async throws {
        let message = MessageBuilder()
            .withId("message-cid-read-drain")
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId("att-cid-read-drain")
            .withFilename("cid.txt")
            .withMimeType("text/plain")
            .queued()
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let downloadedData = Data("old account CID".utf8)
        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses["\(message.id):\(attachment.id!)"] = downloadedData
        let readGate = SuspendedAttachmentRequest(outcome: .success(downloadedData))
        let downloader = AttachmentDownloader(
            apiClient: apiClient,
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            loadAttachmentData: { _ in try? await readGate.perform() }
        )
        let backgroundContext = testStack.newBackgroundContext()
        defer {
            AttachmentPaths.deleteFile(
                at: AttachmentPaths.originalPath(
                    messageId: message.id,
                    attachmentId: "att-cid-read-drain",
                    ext: "txt"
                )
            )
        }

        let cidReadTask = Task { @MainActor in
            await downloader.downloadAttachmentData(
                attachmentObjectID: attachment.objectID,
                messageId: message.id,
                in: backgroundContext
            )
        }
        await readGate.waitUntilStarted()

        let cleanupFinished = AttachmentCleanupFlag()
        let cleanupTask = Task { @MainActor in
            await downloader.cancelAndAwaitAllDownloads()
            cleanupFinished.set()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(
            cleanupFinished.isSet,
            "Account cleanup must wait for the CID file-read continuation"
        )

        await readGate.release()
        await cleanupTask.value
        let result = await cidReadTask.value

        XCTAssertNil(result, "A CID read invalidated by teardown must not publish old-account bytes")
        XCTAssertTrue(cleanupFinished.isSet)
    }

    @MainActor
    func testConcurrentCIDReadsJoinTheSameDownloadAndBothReturnData() async throws {
        let message = MessageBuilder()
            .withId("message-concurrent-cid")
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId("att-concurrent-cid")
            .withFilename("inline.txt")
            .withMimeType("text/plain")
            .queued()
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let downloadedData = Data("shared CID bytes".utf8)
        let request = SuspendedAttachmentRequest(outcome: .success(downloadedData))
        let apiClient = MockGmailAPIClient()
        apiClient.getAttachmentOperation = { _, _ in
            try await request.perform()
        }
        let downloader = AttachmentDownloader(
            apiClient: apiClient,
            coreDataStack: CoreDataStack(
                persistentContainerForTesting: testStack.persistentContainer
            )
        )
        let firstContext = testStack.newBackgroundContext()
        let secondContext = testStack.newBackgroundContext()
        defer {
            AttachmentPaths.deleteFile(
                at: AttachmentPaths.originalPath(
                    messageId: message.id,
                    attachmentId: "att-concurrent-cid",
                    ext: "txt"
                )
            )
        }

        let firstRead = Task { @MainActor in
            await downloader.downloadAttachmentData(
                attachmentObjectID: attachment.objectID,
                messageId: message.id,
                in: firstContext
            )
        }
        await request.waitUntilStarted()

        let secondRead = Task { @MainActor in
            await downloader.downloadAttachmentData(
                attachmentObjectID: attachment.objectID,
                messageId: message.id,
                in: secondContext
            )
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(
            apiClient.getAttachmentCallCountSnapshot(),
            1,
            "A concurrent CID reader must join rather than start or skip the active download"
        )

        await request.release()
        let firstData = await firstRead.value
        let secondData = await secondRead.value

        XCTAssertEqual(firstData, downloadedData)
        XCTAssertEqual(secondData, downloadedData)
        XCTAssertEqual(apiClient.getAttachmentCallCountSnapshot(), 1)
    }

    @MainActor
    func testCancelledCoalescedCIDReadReturnsBeforeOwnerDownloadCompletes() async throws {
        let message = MessageBuilder()
            .withId("message-cancelled-cid-waiter")
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId("att-cancelled-cid-waiter")
            .withFilename("inline.txt")
            .withMimeType("text/plain")
            .queued()
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let downloadedData = Data("owner CID bytes".utf8)
        let request = SuspendedAttachmentRequest(outcome: .success(downloadedData))
        let apiClient = MockGmailAPIClient()
        apiClient.getAttachmentOperation = { _, _ in
            try await request.perform()
        }
        let downloader = AttachmentDownloader(
            apiClient: apiClient,
            coreDataStack: CoreDataStack(
                persistentContainerForTesting: testStack.persistentContainer
            )
        )
        let expectedPath = AttachmentPaths.originalPath(
            messageId: message.id,
            attachmentId: "att-cancelled-cid-waiter",
            ext: "txt"
        )
        defer { AttachmentPaths.deleteFile(at: expectedPath) }

        let firstRead = Task { @MainActor in
            await downloader.downloadAttachmentData(
                attachmentObjectID: attachment.objectID,
                messageId: message.id,
                in: testStack.newBackgroundContext()
            )
        }
        await request.waitUntilStarted()

        let waiterFinished = AttachmentCleanupFlag()
        let secondRead = Task { @MainActor in
            defer { waiterFinished.set() }
            return await downloader.downloadAttachmentData(
                attachmentObjectID: attachment.objectID,
                messageId: message.id,
                in: testStack.newBackgroundContext()
            )
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(apiClient.getAttachmentCallCountSnapshot(), 1)

        secondRead.cancel()
        for _ in 0..<100 where !waiterFinished.isSet {
            await Task.yield()
        }

        XCTAssertTrue(
            waiterFinished.isSet,
            "A cancelled coalesced reader must be removed and resumed without waiting for the owner request"
        )
        if !waiterFinished.isSet {
            // Avoid hanging the test on the exact regression being asserted.
            await request.release()
        }
        let cancelledWaiterData = await secondRead.value
        XCTAssertNil(cancelledWaiterData)

        await request.release()
        let ownerData = await firstRead.value
        XCTAssertEqual(ownerData, downloadedData)
        XCTAssertEqual(apiClient.getAttachmentCallCountSnapshot(), 1)
    }

    @MainActor
    func testPendingSweepRecoversLegacySynthesizedInlineStorageForForwarding() async throws {
        AttachmentPaths.setupDirectories()
        let messageID = "message-legacy-inline-forwarding"
        let authoritativeData = Data("authoritative inline forwarding bytes".utf8)
        let recoveredMessage = makeSynthesizedInlineMessage(
            messageID: messageID,
            data: authoritativeData,
            partID: "1.2",
            filename: "forwarded.txt",
            mimeType: "text/plain",
            contentID: "forwarded-inline@example.com"
        )
        let legacyPath = AttachmentPaths.originalPath(
            idOrUUID: recoveredMessage.attachmentID,
            ext: "txt"
        )
        let staleSiblingData = Data("stale sibling message bytes".utf8)
        XCTAssertTrue(AttachmentPaths.saveData(staleSiblingData, to: legacyPath))

        let message = MessageBuilder()
            .withId(messageID)
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId(recoveredMessage.attachmentID)
            .withFilename("forwarded.txt")
            .withMimeType("text/plain")
            .withContentId("forwarded-inline@example.com")
            .downloaded()
            .withLocalURL(legacyPath)
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let apiClient = MockGmailAPIClient()
        apiClient.getMessageResponses[messageID] = recoveredMessage.message
        let downloader = AttachmentDownloader(
            apiClient: apiClient,
            coreDataStack: CoreDataStack(
                persistentContainerForTesting: testStack.persistentContainer
            )
        )

        await downloader.enqueueAllPendingAttachments()

        let persistedState = try await fetchAttachmentState(
            objectID: attachment.objectID
        )
        let recoveredPath = try XCTUnwrap(persistedState.localURL)
        defer {
            AttachmentPaths.deleteFile(at: legacyPath)
            AttachmentPaths.deleteFile(at: recoveredPath)
        }

        XCTAssertNotEqual(recoveredPath, legacyPath)
        XCTAssertTrue(
            AttachmentPaths.isReadableStoragePath(
                recoveredPath,
                messageId: messageID,
                attachmentId: recoveredMessage.attachmentID
            )
        )
        XCTAssertEqual(AttachmentPaths.loadData(from: recoveredPath), authoritativeData)
        XCTAssertNotEqual(AttachmentPaths.loadData(from: recoveredPath), staleSiblingData)
        XCTAssertEqual(apiClient.getMessageCallCountSnapshot(), 1)
        XCTAssertEqual(apiClient.getAttachmentCallCountSnapshot(), 0)

        context.refresh(attachment, mergeChanges: true)
        let forwardingInfo = try XCTUnwrap(
            OutboundAttachmentContextBuilder(viewContext: context)
                .buildInlineAttachmentInfos(from: [attachment])
                .first
        )
        XCTAssertEqual(forwardingInfo.localURL, recoveredPath)
        XCTAssertEqual(AttachmentPaths.loadData(from: forwardingInfo.localURL), authoritativeData)
    }

    @MainActor
    func testConcurrentSynthesizedInlineSiblingReadsShareMessageRecoveryAfterOwnerCancellation() async throws {
        AttachmentPaths.setupDirectories()
        let messageID = "message-concurrent-inline-siblings-\(UUID().uuidString)"
        let firstData = Data("first inline sibling".utf8)
        let secondData = Data("second inline sibling".utf8)
        let firstRecovered = makeSynthesizedInlineMessage(
            messageID: messageID,
            data: firstData,
            partID: "1.1",
            filename: "first.txt",
            mimeType: "text/plain",
            contentID: "first-inline@example.com"
        )
        let secondRecovered = makeSynthesizedInlineMessage(
            messageID: messageID,
            data: secondData,
            partID: "1.2",
            filename: "second.txt",
            mimeType: "text/plain",
            contentID: "second-inline@example.com"
        )
        let firstPart = try XCTUnwrap(firstRecovered.message.payload?.parts?.first)
        let secondPart = try XCTUnwrap(secondRecovered.message.payload?.parts?.first)
        let recoveredMessage = GmailMessage(
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
                parts: [firstPart, secondPart]
            ),
            sizeEstimate: firstData.count + secondData.count
        )

        let message = MessageBuilder()
            .withId(messageID)
            .withAttachments()
            .build(in: context)
        let firstAttachment = AttachmentBuilder()
            .withId(firstRecovered.attachmentID)
            .withFilename("first.txt")
            .withMimeType("text/plain")
            .withContentId("first-inline@example.com")
            .queued()
            .forMessage(message)
            .build(in: context)
        let secondAttachment = AttachmentBuilder()
            .withId(secondRecovered.attachmentID)
            .withFilename("second.txt")
            .withMimeType("text/plain")
            .withContentId("second-inline@example.com")
            .queued()
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let firstPath = AttachmentPaths.originalPath(
            messageId: messageID,
            attachmentId: firstRecovered.attachmentID,
            ext: "txt"
        )
        let secondPath = AttachmentPaths.originalPath(
            messageId: messageID,
            attachmentId: secondRecovered.attachmentID,
            ext: "txt"
        )
        defer {
            AttachmentPaths.deleteFile(at: firstPath)
            AttachmentPaths.deleteFile(at: secondPath)
        }

        let apiClient = MockGmailAPIClient()
        let messageRequest = SuspendedMessageRequest(message: recoveredMessage)
        apiClient.getMessageOperation = { _, _ in
            await messageRequest.perform()
        }
        let downloader = AttachmentDownloader(
            apiClient: apiClient,
            coreDataStack: CoreDataStack(
                persistentContainerForTesting: testStack.persistentContainer
            )
        )

        let ownerFinished = AttachmentCleanupFlag()
        let ownerRead = Task { @MainActor in
            defer { ownerFinished.set() }
            return await downloader.downloadAttachmentData(
                attachmentObjectID: firstAttachment.objectID,
                messageId: messageID,
                in: testStack.newBackgroundContext()
            )
        }
        await messageRequest.waitUntilStarted()
        XCTAssertEqual(apiClient.getMessageCallCountSnapshot(), 1)

        let siblingRead = Task { @MainActor in
            await downloader.downloadAttachmentData(
                attachmentObjectID: secondAttachment.objectID,
                messageId: messageID,
                in: testStack.newBackgroundContext()
            )
        }
        for _ in 0..<100 where apiClient.getMessageCallCountSnapshot() == 1 {
            await Task.yield()
        }
        XCTAssertEqual(
            apiClient.getMessageCallCountSnapshot(),
            1,
            "Synthesized inline siblings must join the message-level recovery"
        )

        ownerRead.cancel()
        for _ in 0..<100 where !ownerFinished.isSet {
            await Task.yield()
        }
        XCTAssertTrue(
            ownerFinished.isSet,
            "A canceled CID owner must stop waiting while shared recovery continues for siblings"
        )
        if !ownerFinished.isSet {
            // Avoid hanging the test on the exact regression being asserted.
            await messageRequest.release()
        }
        let ownerResult = await ownerRead.value
        XCTAssertNil(ownerResult)

        await messageRequest.release()
        let siblingResult = await siblingRead.value

        XCTAssertEqual(siblingResult, secondData)
        XCTAssertEqual(apiClient.getMessageCallCountSnapshot(), 1)

        let firstState = try await fetchAttachmentState(objectID: firstAttachment.objectID)
        let secondState = try await fetchAttachmentState(objectID: secondAttachment.objectID)
        XCTAssertEqual(firstState.state, .downloaded)
        XCTAssertEqual(secondState.state, .downloaded)
        XCTAssertEqual(firstState.localURL, firstPath)
        XCTAssertEqual(secondState.localURL, secondPath)
        XCTAssertEqual(AttachmentPaths.loadData(from: firstPath), firstData)
        XCTAssertEqual(AttachmentPaths.loadData(from: secondPath), secondData)
    }

    func testSynthesizedInlineRecoveredMetadataClampsToInt16Bounds() {
        XCTAssertEqual(
            SynthesizedInlineAttachmentRecovery.persistedImageDimension(
                CGFloat(Int16.max) + 10_000
            ),
            Int16.max
        )
        XCTAssertEqual(
            SynthesizedInlineAttachmentRecovery.persistedImageDimension(1_024.4),
            1_024
        )
        XCTAssertEqual(
            SynthesizedInlineAttachmentRecovery.persistedPDFPageCount(Int.max),
            Int16.max
        )
        XCTAssertEqual(
            SynthesizedInlineAttachmentRecovery.persistedPDFPageCount(12),
            12
        )
    }

    @MainActor
    func testCIDReadDoesNotReturnLegacyPathAfterRedownloadFails() async throws {
        let message = MessageBuilder()
            .withId("message-cid-legacy-failure")
            .withAttachments()
            .build(in: context)
        let attachmentID = "attachment-cid-legacy-failure"
        let legacyPath = AttachmentPaths.originalPath(idOrUUID: attachmentID, ext: "png")
        let attachment = AttachmentBuilder()
            .withId(attachmentID)
            .withFilename("legacy.png")
            .withMimeType("image/png")
            .downloaded()
            .withLocalURL(legacyPath)
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let staleBytes = Data("another message's bytes".utf8)
        let downloader = AttachmentDownloader(
            apiClient: MockGmailAPIClient(),
            coreDataStack: CoreDataStack(
                persistentContainerForTesting: testStack.persistentContainer
            ),
            maxRetryAttempts: 1,
            baseRetryDelay: 0,
            loadAttachmentData: { path in
                path == legacyPath ? staleBytes : nil
            }
        )

        let result = await downloader.downloadAttachmentData(
            attachmentObjectID: attachment.objectID,
            messageId: message.id,
            in: testStack.newBackgroundContext()
        )

        XCTAssertNil(result)
        let persistedState = try await fetchAttachmentState(objectID: attachment.objectID)
        XCTAssertEqual(persistedState.state, .failed)
        XCTAssertEqual(persistedState.localURL, legacyPath)
    }

    @MainActor
    func testSuccessfulMigrationClearsLegacyPreviewWhenThumbnailCannotBeGenerated() async throws {
        let message = MessageBuilder()
            .withId("message-preview-migration")
            .withAttachments()
            .build(in: context)
        let attachmentID = "attachment-preview-migration-\(UUID().uuidString)"
        let attachment = AttachmentBuilder()
            .withId(attachmentID)
            .withFilename("invalid.png")
            .withMimeType("image/png")
            .downloaded()
            .withLocalURL(AttachmentPaths.originalPath(idOrUUID: attachmentID, ext: "png"))
            .withPreviewURL(AttachmentPaths.previewPath(idOrUUID: attachmentID))
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses["\(message.id):\(attachmentID)"] = Data("not an image".utf8)
        let downloader = AttachmentDownloader(
            apiClient: apiClient,
            coreDataStack: CoreDataStack(
                persistentContainerForTesting: testStack.persistentContainer
            )
        )
        let expectedOriginalPath = AttachmentPaths.originalPath(
            messageId: message.id,
            attachmentId: attachmentID,
            ext: "png"
        )
        defer {
            AttachmentPaths.deleteFile(at: expectedOriginalPath)
            AttachmentPaths.deleteFile(
                at: AttachmentPaths.previewPath(
                    messageId: message.id,
                    attachmentId: attachmentID
                )
            )
        }

        await downloader.downloadAttachment(
            attachmentObjectID: attachment.objectID,
            messageId: message.id,
            in: testStack.newBackgroundContext()
        )

        let persistedState = try await fetchAttachmentState(objectID: attachment.objectID)
        XCTAssertEqual(persistedState.state, .downloaded)
        XCTAssertEqual(persistedState.localURL, expectedOriginalPath)
        XCTAssertNil(persistedState.previewURL)

        context.refresh(attachment, mergeChanges: true)
        XCTAssertFalse(attachment.needsRedownload)
    }

    @MainActor
    func testConcurrentReusedAttachmentIDKeepsMessageFilesAndRollbackIsolated() async throws {
        let sharedAttachmentID = "shared-remote-attachment-\(UUID().uuidString)"
        let firstMessage = MessageBuilder()
            .withId("message-shared-attachment-first")
            .withAttachments()
            .build(in: context)
        let secondMessage = MessageBuilder()
            .withId("message-shared-attachment-second")
            .withAttachments()
            .build(in: context)
        let failingMessage = MessageBuilder()
            .withId("message-shared-attachment-failing")
            .withAttachments()
            .build(in: context)
        let firstAttachment = AttachmentBuilder()
            .withId(sharedAttachmentID)
            .withFilename("first.dat")
            .withMimeType("application/octet-stream")
            .queued()
            .forMessage(firstMessage)
            .build(in: context)
        let secondAttachment = AttachmentBuilder()
            .withId(sharedAttachmentID)
            .withFilename("second.dat")
            .withMimeType("application/octet-stream")
            .queued()
            .forMessage(secondMessage)
            .build(in: context)
        let failingAttachment = AttachmentBuilder()
            .withId(sharedAttachmentID)
            .withFilename("failing.dat")
            .withMimeType("application/octet-stream")
            .queued()
            .forMessage(failingMessage)
            .build(in: context)
        try testStack.saveViewContext()

        let firstData = Data("first message bytes".utf8)
        let secondData = Data("second message bytes".utf8)
        let requestGate = MessageScopedAttachmentRequestGate(
            outcomes: [
                firstMessage.id: .success(firstData),
                secondMessage.id: .success(secondData),
                failingMessage.id: .failure
            ]
        )
        let apiClient = MockGmailAPIClient()
        apiClient.getAttachmentOperation = { messageId, _ in
            try await requestGate.perform(messageId: messageId)
        }
        let downloader = AttachmentDownloader(
            apiClient: apiClient,
            coreDataStack: CoreDataStack(
                persistentContainerForTesting: testStack.persistentContainer
            ),
            maxRetryAttempts: 1,
            baseRetryDelay: 0
        )

        let firstTask = Task { @MainActor in
            await downloader.downloadAttachment(
                attachmentObjectID: firstAttachment.objectID,
                messageId: firstMessage.id,
                in: testStack.newBackgroundContext()
            )
        }
        let secondTask = Task { @MainActor in
            await downloader.downloadAttachment(
                attachmentObjectID: secondAttachment.objectID,
                messageId: secondMessage.id,
                in: testStack.newBackgroundContext()
            )
        }
        let failingTask = Task { @MainActor in
            await downloader.downloadAttachment(
                attachmentObjectID: failingAttachment.objectID,
                messageId: failingMessage.id,
                in: testStack.newBackgroundContext()
            )
        }

        await requestGate.waitUntilStarted(count: 3)

        XCTAssertTrue(
            downloader.isDownloading(
                messageId: firstMessage.id,
                attachmentId: sharedAttachmentID
            )
        )
        XCTAssertTrue(
            downloader.isDownloading(
                messageId: secondMessage.id,
                attachmentId: sharedAttachmentID
            )
        )
        XCTAssertTrue(
            downloader.isDownloading(
                messageId: failingMessage.id,
                attachmentId: sharedAttachmentID
            )
        )

        await requestGate.release(messageId: firstMessage.id)
        await firstTask.value

        // Revert-check: replacing isDownloading(messageId:attachmentId:) with
        // attachment-ID-only state makes this completed message inherit either
        // sibling's still-active spinner.
        XCTAssertFalse(
            downloader.isDownloading(
                messageId: firstMessage.id,
                attachmentId: sharedAttachmentID
            )
        )
        XCTAssertNil(
            downloader.downloadProgress(
                messageId: firstMessage.id,
                attachmentId: sharedAttachmentID
            )
        )
        XCTAssertTrue(
            downloader.isDownloading(
                messageId: secondMessage.id,
                attachmentId: sharedAttachmentID
            )
        )
        XCTAssertTrue(
            downloader.isDownloading(
                messageId: failingMessage.id,
                attachmentId: sharedAttachmentID
            )
        )

        await requestGate.release(messageId: secondMessage.id)
        await secondTask.value

        let firstState = try await fetchAttachmentState(objectID: firstAttachment.objectID)
        let secondState = try await fetchAttachmentState(objectID: secondAttachment.objectID)
        let firstPath = try XCTUnwrap(firstState.localURL)
        let secondPath = try XCTUnwrap(secondState.localURL)
        defer {
            AttachmentPaths.deleteFile(at: firstPath)
            AttachmentPaths.deleteFile(at: secondPath)
        }

        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertEqual(AttachmentPaths.loadData(from: firstPath), firstData)
        XCTAssertEqual(AttachmentPaths.loadData(from: secondPath), secondData)

        // Release a sibling failure only after both successful files exist.
        // Its rollback must not delete either successful message's bytes.
        await requestGate.release(messageId: failingMessage.id)
        await failingTask.value

        let failingState = try await fetchAttachmentState(objectID: failingAttachment.objectID)
        XCTAssertEqual(failingState.state, .failed)
        XCTAssertNil(failingState.localURL)
        XCTAssertEqual(AttachmentPaths.loadData(from: firstPath), firstData)
        XCTAssertEqual(AttachmentPaths.loadData(from: secondPath), secondData)
    }

    @MainActor
    func testCleanupOrphanedFilesCannotStartWhileAccountDownloadsAreSuspended() async throws {
        let attachmentID = "teardown-orphan-\(UUID().uuidString)"
        let relativePath = AttachmentPaths.originalPath(idOrUUID: attachmentID, ext: "dat")
        let fileURL = try XCTUnwrap(AttachmentPaths.fullURL(for: relativePath))
        XCTAssertTrue(AttachmentPaths.saveData(Data("old account".utf8), to: relativePath))
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let downloader = AttachmentDownloader(
            apiClient: MockGmailAPIClient(),
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        )
        await downloader.cancelAndAwaitAllDownloads()

        await downloader.cleanupOrphanedFiles()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "A maintenance task arriving during account teardown must be rejected before deleting files"
        )
    }

    @MainActor
    func testReopenAdmissionRecreatesDirectoriesAfterAccountCleanup() async {
        let directoryPreparation = SynchronousCallCounter()
        let downloader = AttachmentDownloader(
            apiClient: MockGmailAPIClient(),
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            prepareDownloadDirectories: {
                directoryPreparation.increment()
            }
        )
        XCTAssertEqual(directoryPreparation.count, 1)

        await downloader.cancelAndAwaitAllDownloads()
        XCTAssertTrue(downloader.reopenAdmission())

        XCTAssertEqual(
            directoryPreparation.count,
            2,
            "Same-process sign-in must recreate directories removed by account cleanup"
        )
    }

    // Revert-check: fails if `AttachmentDownloader.reopenAdmission()` stops
    // returning false from its `activeDownloadOperations.isEmpty` guard (for
    // example by reverting to the Void signature that swallowed the refusal).
    // AuthSession maps that false onto an all-or-none reopen failure, so
    // swallowing it publishes a session whose downloads can never be admitted.
    //
    // HONEST SCOPE: the outstanding operation is manufactured by holding the
    // attachment request gate. AuthSession always drains through
    // `cancelAndAwaitAllDownloads()` before reopening, so this state is
    // unreachable through the account transition paths today; the assertion
    // pins the guard's refusal, not a live regression.
    @MainActor
    func testReopenAdmissionRefusesWhileClosedAccountDownloadIsOutstanding() async throws {
        let attachmentID = "reopen-refusal-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId("message-reopen-refusal")
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId(attachmentID)
            .withFilename("outstanding.dat")
            .withMimeType("application/octet-stream")
            .queued()
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let requestGate = MessageScopedAttachmentRequestGate(
            outcomes: [message.id: .failure]
        )
        let apiClient = MockGmailAPIClient()
        apiClient.getAttachmentOperation = { messageId, _ in
            try await requestGate.perform(messageId: messageId)
        }
        let downloader = AttachmentDownloader(
            apiClient: apiClient,
            coreDataStack: CoreDataStack(
                persistentContainerForTesting: testStack.persistentContainer
            ),
            maxRetryAttempts: 1,
            baseRetryDelay: 0
        )

        let downloadTask = Task { @MainActor in
            await downloader.downloadAttachment(
                attachmentObjectID: attachment.objectID,
                messageId: message.id,
                in: testStack.newBackgroundContext()
            )
        }
        await requestGate.waitUntilStarted(count: 1)

        XCTAssertFalse(
            downloader.reopenAdmission(),
            "Download admission must stay closed while an old-account download is still live"
        )

        await requestGate.release(messageId: message.id)
        await downloadTask.value

        XCTAssertTrue(
            downloader.reopenAdmission(),
            "Download admission must reopen once every old-account download has unwound"
        )
    }

    // MARK: - Query Tests

    func testFetchAttachments_filtersByState() throws {
        // Create attachments with different states
        let _ = AttachmentBuilder()
            .withId("att-queued")
            .queued()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-downloaded")
            .downloaded()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-failed")
            .failed()
            .build(in: context)

        try testStack.saveViewContext()

        // Fetch queued only (like AttachmentDownloader.enqueueAllPendingAttachments)
        let request = Attachment.fetchRequest()
        request.predicate = NSPredicate(format: "stateRaw == %@", "queued")

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "att-queued")
    }

    func testFetchAttachments_filtersByQueuedOrFailed() throws {
        // Create attachments with different states
        let _ = AttachmentBuilder()
            .withId("att-queued")
            .queued()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-downloaded")
            .downloaded()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-failed")
            .failed()
            .build(in: context)

        try testStack.saveViewContext()

        // Fetch queued or failed (downloadable attachments)
        let request = Attachment.fetchRequest()
        request.predicate = NSPredicate(format: "stateRaw == %@ OR stateRaw == %@", "queued", "failed")

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 2)
        let ids = Set(results.compactMap { $0.id })
        XCTAssertTrue(ids.contains("att-queued"))
        XCTAssertTrue(ids.contains("att-failed"))
    }

    // MARK: - isImage / isPDF Tests

    func testAttachment_isImage_returnsCorrectly() throws {
        let jpegAttachment = AttachmentBuilder()
            .withMimeType("image/jpeg")
            .build(in: context)
        XCTAssertTrue(jpegAttachment.isImage)

        let pngAttachment = AttachmentBuilder()
            .withMimeType("image/png")
            .build(in: context)
        XCTAssertTrue(pngAttachment.isImage)

        let pdfAttachment = AttachmentBuilder()
            .withMimeType("application/pdf")
            .build(in: context)
        XCTAssertFalse(pdfAttachment.isImage)

        let textAttachment = AttachmentBuilder()
            .withMimeType("text/plain")
            .build(in: context)
        XCTAssertFalse(textAttachment.isImage)
    }

    func testAttachment_isPDF_returnsCorrectly() throws {
        let pdfAttachment = AttachmentBuilder()
            .withMimeType("application/pdf")
            .build(in: context)
        XCTAssertTrue(pdfAttachment.isPDF)

        let imageAttachment = AttachmentBuilder()
            .withMimeType("image/jpeg")
            .build(in: context)
        XCTAssertFalse(imageAttachment.isPDF)
    }

    func testAttachment_isVideo_returnsCorrectly() throws {
        let mp4Attachment = AttachmentBuilder()
            .withMimeType("video/mp4")
            .build(in: context)
        XCTAssertTrue(mp4Attachment.isVideo)

        let movAttachment = AttachmentBuilder()
            .withMimeType("video/quicktime")
            .build(in: context)
        XCTAssertTrue(movAttachment.isVideo)

        let pdfAttachment = AttachmentBuilder()
            .withMimeType("application/pdf")
            .build(in: context)
        XCTAssertFalse(pdfAttachment.isVideo)
    }

    // MARK: - Signature Image Detection Tests

    func testAttachment_isLikelySignatureImage_smallByteSize() throws {
        // Attachment under 10KB should be detected as likely signature
        let smallAttachment = AttachmentBuilder()
            .asImage(width: 200, height: 100)
            .withByteSize(5000) // 5KB
            .build(in: context)

        XCTAssertTrue(smallAttachment.isLikelySignatureImage, "Small image under 10KB should be likely signature")
    }

    func testAttachment_isLikelySignatureImage_smallDimensions() throws {
        // Attachment with both dimensions <= 100px should be detected as likely signature
        let smallDimensionsAttachment = AttachmentBuilder()
            .asImage(width: 80, height: 80)
            .withByteSize(50000) // 50KB - larger than threshold
            .build(in: context)

        XCTAssertTrue(smallDimensionsAttachment.isLikelySignatureImage, "Image with dimensions <= 100px should be likely signature")
    }

    func testAttachment_isLikelySignatureImage_largeImageIsNotSignature() throws {
        // Normal-sized image should not be detected as signature
        let normalAttachment = AttachmentBuilder()
            .asImage(width: 800, height: 600)
            .withByteSize(500000) // 500KB
            .build(in: context)

        XCTAssertFalse(normalAttachment.isLikelySignatureImage, "Normal sized image should not be detected as signature")
    }

    func testAttachment_isLikelySignatureImage_nonImageIsNotSignature() throws {
        // Non-image attachment should not be detected as signature
        let pdfAttachment = AttachmentBuilder()
            .asPDF()
            .withByteSize(5000) // Small but not an image
            .build(in: context)

        XCTAssertFalse(pdfAttachment.isLikelySignatureImage, "Non-image attachment should not be detected as signature")
    }


    // MARK: - displayableAttachments Tests

    /// Builds the same analysis the live render path computes (ChatMessageRowModel
    /// carries the snapshot equivalent); the legacy Message-internal HTML loading
    /// paths were deleted in favor of this.
    private func builtHTMLAnalysis(for message: Message) -> MessageBubbleHTMLAnalysis {
        MessageBubbleHTMLAnalysisBuilder.build(
            messageID: message.id,
            bodyStorageURI: message.bodyStorageURI,
            hasHTMLSourceHint: message.hasHTMLSource,
            isForwardedEmail: message.isForwardedEmail,
            isLikelyCalendarInvite: message.isLikelyCalendarInvite,
            bodyText: message.bodyText,
            cleanedSnippet: message.cleanedSnippet,
            subject: message.subject,
            attachmentSnapshots: message.attachmentsArray.map(\.bubbleSnapshot),
            handler: HTMLContentHandler.shared
        )
    }

    func testMessage_displayableAttachments_filtersSignatureImages() throws {
        let message = MessageBuilder()
            .withId("msg-with-attachments")
            .withAttachments()
            .build(in: context)

        // Add a normal image
        let _ = AttachmentBuilder()
            .withId("att-normal")
            .asImage(width: 800, height: 600)
            .withByteSize(100000)
            .forMessage(message)
            .build(in: context)

        // Add a signature image (small bytes)
        let _ = AttachmentBuilder()
            .withId("att-signature")
            .asImage(width: 200, height: 50)
            .withByteSize(5000) // Under 10KB
            .forMessage(message)
            .build(in: context)

        try testStack.saveViewContext()

        // Fetch fresh message
        let fetchedMessage = try context.existingObject(with: message.objectID) as? Message

        let displayable = fetchedMessage.map {
            $0.displayableAttachments(using: builtHTMLAnalysis(for: $0), hidingInlineReferencedInHTML: true)
        } ?? []

        // Should only include the normal image, not the signature
        XCTAssertEqual(displayable.count, 1)
        XCTAssertEqual(displayable.first?.id, "att-normal")
    }

    func testMessage_displayableAttachments_hidingInlineReferencedInHTML_filtersCIDReferencedInlineImages() throws {
        let messageId = "msg-inline-filter-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withAttachments()
            .build(in: context)

        // Attachment referenced by cid: in HTML should be hidden when `hidingInlineReferencedInHTML` is true.
        let _ = AttachmentBuilder()
            .withId("att-inline")
            .withFilename("inline.jpg")
            .withContentId("CID_INLINE")
            .asImage(width: 800, height: 600)
            .withByteSize(100000)
            .forMessage(message)
            .build(in: context)

        // Attachment not referenced by cid: should remain visible.
        let _ = AttachmentBuilder()
            .withId("att-regular")
            .withFilename("regular.jpg")
            .withContentId("CID_OTHER")
            .asImage(width: 800, height: 600)
            .withByteSize(100000)
            .forMessage(message)
            .build(in: context)

        let handler = HTMLContentHandler.shared
        _ = handler.saveHTML("<html><body><img src=\"cid:CID_INLINE\"></body></html>", for: messageId)

        try testStack.saveViewContext()

        let fetchedMessage = try XCTUnwrap(context.existingObject(with: message.objectID) as? Message)
        let analysis = builtHTMLAnalysis(for: fetchedMessage)
        let hiddenInline = fetchedMessage.displayableAttachments(using: analysis, hidingInlineReferencedInHTML: true)
        XCTAssertEqual(hiddenInline.compactMap { $0.id }.sorted(), ["att-regular"])

        let showAll = fetchedMessage.displayableAttachments(using: analysis, hidingInlineReferencedInHTML: false)
        XCTAssertEqual(showAll.compactMap { $0.id }.sorted(), ["att-inline", "att-regular"])

        handler.deleteHTML(for: messageId)
    }

    func testMessage_displayableAttachments_usingPrecomputedHTMLAnalysis_filtersCIDReferencedInlineImages() throws {
        let messageId = "msg-inline-analysis-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withAttachments()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-inline")
            .withFilename("inline.jpg")
            .withContentId("CID_INLINE")
            .asImage(width: 800, height: 600)
            .withByteSize(100000)
            .forMessage(message)
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-regular")
            .withFilename("regular.jpg")
            .withContentId("CID_OTHER")
            .asImage(width: 800, height: 600)
            .withByteSize(100000)
            .forMessage(message)
            .build(in: context)

        let handler = HTMLContentHandler.shared
        _ = handler.saveHTML("<html><body><img src=\"cid:CID_INLINE\"></body></html>", for: messageId)
        defer { handler.deleteHTML(for: messageId) }

        try testStack.saveViewContext()

        let fetchedMessage = try XCTUnwrap(
            context.existingObject(with: message.objectID) as? Message
        )
        let htmlAnalysis = MessageBubbleHTMLAnalysisBuilder.build(
            messageID: fetchedMessage.id,
            bodyStorageURI: fetchedMessage.bodyStorageURI,
            hasHTMLSourceHint: fetchedMessage.bodyStorageURI != nil,
            isForwardedEmail: fetchedMessage.isForwardedEmail,
            isLikelyCalendarInvite: fetchedMessage.isLikelyCalendarInvite,
            bodyText: fetchedMessage.bodyText,
            cleanedSnippet: fetchedMessage.cleanedSnippet,
            subject: fetchedMessage.subject,
            attachmentSnapshots: fetchedMessage.attachmentsArray.map(\.bubbleSnapshot),
            handler: handler
        )

        let displayable = fetchedMessage.displayableAttachments(
            using: htmlAnalysis,
            hidingInlineReferencedInHTML: true
        )

        XCTAssertEqual(displayable.compactMap { $0.id }.sorted(), ["att-regular"])
    }

    func testMessage_displayableAttachments_hidesCalendarInviteFilesOnlyInPreviewMode() throws {
        let messageId = "msg-calendar-preview-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withSubject("Invitation: Board sync @ Mon May 5, 2026 9:00am - 9:30am (EDT)")
            .withSnippet("Invitation from Google Calendar")
            .withBody(
                """
                Invitation from Google Calendar
                Board sync
                When
                Monday May 5, 2026 • 9:00am – 9:30am (Eastern Time - New York)
                Guests
                brynn@example.com
                Reply for kmthau@gmail.com
                """
            )
            .withAttachments()
            .build(in: context)

        // The live analysis only reports calendar-card support for messages
        // that actually have HTML (no HTML → placeholder analysis → nothing
        // hidden); the deleted Message-internal path conjured a card from
        // bodyText alone.
        let handler = HTMLContentHandler.shared
        _ = handler.saveHTML(
            "<html><body><div>Invitation from Google Calendar</div><div>Board sync</div></body></html>",
            for: messageId
        )
        defer { handler.deleteHTML(for: messageId) }

        let _ = AttachmentBuilder()
            .withId("att-calendar")
            .withFilename("invite.ics")
            .withMimeType("text/calendar")
            .withByteSize(2_048)
            .forMessage(message)
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-notes")
            .withFilename("notes.pdf")
            .asPDF()
            .withByteSize(45_000)
            .forMessage(message)
            .build(in: context)

        try testStack.saveViewContext()

        let fetchedMessage = try XCTUnwrap(context.existingObject(with: message.objectID) as? Message)
        let analysis = builtHTMLAnalysis(for: fetchedMessage)

        let previewAttachments = fetchedMessage.displayableAttachments(using: analysis, hidingInlineReferencedInHTML: true)
        XCTAssertEqual(previewAttachments.compactMap { $0.id }, ["att-notes"])

        let bubbleAttachments = fetchedMessage.displayableAttachments(using: analysis, hidingInlineReferencedInHTML: false)
        XCTAssertEqual(bubbleAttachments.compactMap { $0.id }.sorted(), ["att-calendar", "att-notes"])
    }

    func testMessage_displayableAttachments_keepsCalendarInviteFileWhenPreviewCardIsUnsupported() throws {
        let messageId = "msg-calendar-unsupported-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withSubject("Invitation: Vendor sync @ Mon May 5, 2026 9:00am - 9:30am (EDT)")
            .withSnippet("Please review the attached invite")
            .withBody("Please review the attached invite.")
            .withAttachments()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-calendar")
            .withFilename("invite.ics")
            .withMimeType("text/calendar")
            .withByteSize(2_048)
            .forMessage(message)
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-notes")
            .withFilename("notes.pdf")
            .asPDF()
            .withByteSize(45_000)
            .forMessage(message)
            .build(in: context)

        let handler = HTMLContentHandler.shared
        _ = handler.saveHTML("<html><body><div>Please review the attached invite.</div></body></html>", for: messageId)
        defer { handler.deleteHTML(for: messageId) }

        try testStack.saveViewContext()

        let fetchedMessage = try XCTUnwrap(context.existingObject(with: message.objectID) as? Message)
        let analysis = builtHTMLAnalysis(for: fetchedMessage)

        XCTAssertEqual(fetchedMessage.isLikelyCalendarInvite, true)
        XCTAssertEqual(analysis.supportsCalendarInvitePreviewCard, false)

        let previewAttachments = fetchedMessage.displayableAttachments(using: analysis, hidingInlineReferencedInHTML: true)
        XCTAssertEqual(previewAttachments.compactMap { $0.id }.sorted(), ["att-calendar", "att-notes"])
    }

    func testMessage_displayableAttachments_htmlLessInvite_keepsCalendarFileVisible() throws {
        // Pins live behavior for plain-text calendar invites (no persisted
        // HTML): the analysis is a placeholder with no preview-card support,
        // so nothing hides the .ics — the attachment stays reachable instead
        // of being hidden for a card that will never render. (The deleted
        // Message-internal path conjured a card from bodyText alone.)
        let message = MessageBuilder()
            .withId("msg-calendar-htmlless-\(UUID().uuidString)")
            .withSubject("Invitation: Standup @ Tue May 6, 2026 10:00am - 10:15am (EDT)")
            .withSnippet("Invitation from Google Calendar")
            .withBody(
                """
                Invitation from Google Calendar
                Standup
                When
                Tuesday May 6, 2026 • 10:00am – 10:15am (Eastern Time - New York)
                Guests
                brynn@example.com
                """
            )
            .withAttachments()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-calendar")
            .withFilename("invite.ics")
            .withMimeType("text/calendar")
            .withByteSize(2_048)
            .forMessage(message)
            .build(in: context)

        try testStack.saveViewContext()

        let fetchedMessage = try XCTUnwrap(context.existingObject(with: message.objectID) as? Message)
        let analysis = builtHTMLAnalysis(for: fetchedMessage)

        XCTAssertTrue(fetchedMessage.isLikelyCalendarInvite)
        XCTAssertFalse(analysis.supportsCalendarInvitePreviewCard, "no HTML → placeholder analysis → no card")

        let previewAttachments = fetchedMessage.displayableAttachments(using: analysis, hidingInlineReferencedInHTML: true)
        XCTAssertEqual(previewAttachments.compactMap { $0.id }, ["att-calendar"])
    }

    func testMessage_displayableAttachments_plainBubble_hidesSignatureOnlyCIDInlineImages() throws {
        let messageId = "msg-inline-signature-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withAttachments()
            .build(in: context)

        // Signature/logo CID image should be hidden even in plain bubble mode.
        let _ = AttachmentBuilder()
            .withId("att-signature-inline")
            .withFilename("image001.png")
            .withContentId("image001.png@01DC96AF.8C2488C0")
            .asImage(width: 512, height: 512) // Not caught by size/dimension signature heuristic alone
            .withByteSize(31_639)
            .forMessage(message)
            .build(in: context)

        // Real inline body image should still be shown in plain bubble mode.
        let _ = AttachmentBuilder()
            .withId("att-body-inline")
            .withFilename("site-photo.png")
            .withContentId("body-inline-image")
            .asImage(width: 1200, height: 900)
            .withByteSize(350_000)
            .forMessage(message)
            .build(in: context)

        // Regular non-inline attachment should always remain visible.
        let _ = AttachmentBuilder()
            .withId("att-regular-file")
            .withFilename("notes.pdf")
            .asPDF()
            .withByteSize(45_000)
            .forMessage(message)
            .build(in: context)

        let handler = HTMLContentHandler.shared
        _ = handler.saveHTML(
            """
            <html><body>
            <div>Hope everyone had a good week!</div>
            <div><img src="cid:body-inline-image"></div>
            <div id="ms-outlook-mobile-signature">
                <p>Ally Varady</p>
                <p><img src="cid:image001.png@01DC96AF.8C2488C0"></p>
            </div>
            </body></html>
            """,
            for: messageId
        )

        try testStack.saveViewContext()

        let fetchedMessage = try XCTUnwrap(context.existingObject(with: message.objectID) as? Message)
        let displayable = fetchedMessage.displayableAttachments(
            using: builtHTMLAnalysis(for: fetchedMessage),
            hidingInlineReferencedInHTML: false
        )

        XCTAssertEqual(displayable.compactMap { $0.id }.sorted(), ["att-body-inline", "att-regular-file"])

        handler.deleteHTML(for: messageId)
    }

    func testMessage_displayableAttachments_plainBubble_hidesOutlookWordSignatureLogoWithoutWrapper() throws {
        let messageId = "msg-inline-outlook-word-signature-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withAttachments()
            .build(in: context)

        // Outlook/Word signature logo (generic image001 filename + CID) should not show as attachment.
        let _ = AttachmentBuilder()
            .withId("att-signature-word-inline")
            .withFilename("image001.png")
            .withContentId("image001.png@01DCA5AF.35846080")
            .asImage(width: 134, height: 53)
            .withByteSize(192_520)
            .forMessage(message)
            .build(in: context)

        // Real file attachment should remain visible.
        let _ = AttachmentBuilder()
            .withId("att-real-file")
            .withFilename("ABT x Casa Tua Invitation.png")
            .asImage(width: 1024, height: 1536)
            .withByteSize(3_467_325)
            .forMessage(message)
            .build(in: context)

        let handler = HTMLContentHandler.shared
        _ = handler.saveHTML(
            """
            <html><body>
            <div>Hi Brynn and Kevin,</div>
            <div>I hope that you are staying warm and doing well!</div>
            <div>Warmly,</div>
            <div>Katherine</div>
            <div><strong>Katherine Merwin</strong></div>
            <div>Global Membership Manager</div>
            <div><img src="cid:image001.png@01DCA5AF.35846080" alt="logo"></div>
            </body></html>
            """,
            for: messageId
        )

        try testStack.saveViewContext()

        let fetchedMessage = try XCTUnwrap(context.existingObject(with: message.objectID) as? Message)
        let displayable = fetchedMessage.displayableAttachments(
            using: builtHTMLAnalysis(for: fetchedMessage),
            hidingInlineReferencedInHTML: false
        )

        XCTAssertEqual(displayable.compactMap { $0.id }.sorted(), ["att-real-file"])

        handler.deleteHTML(for: messageId)
    }

    func testMessage_displayableAttachments_plainBubble_usesBodyStorageURIHTMLFallback() throws {
        let messageId = "msg-inline-body-storage-uri-fallback-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withAttachments()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-signature-uri-inline")
            .asImage(width: 134, height: 53)
            .withFilename("image001.png")
            .withContentId("image001.png@01DCA5AF.35846080")
            .withByteSize(192_520)
            .forMessage(message)
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-real-uri-file")
            .asImage(width: 1024, height: 1536)
            .withFilename("ABT x Casa Tua Invitation.png")
            .withByteSize(3_467_325)
            .forMessage(message)
            .build(in: context)

        let html = """
        <html><body>
        <div>Hi Brynn and Kevin,</div>
        <div>I hope that you are staying warm and doing well!</div>
        <div>Warmly,</div>
        <div>Katherine</div>
        <div><strong>Katherine Merwin</strong></div>
        <div>Global Membership Manager</div>
        <div><img src="cid:image001.png@01DCA5AF.35846080" alt="logo"></div>
        </body></html>
        """

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("body-storage-fallback-\(UUID().uuidString).html")
        try html.write(to: tempURL, atomically: true, encoding: .utf8)

        let handler = HTMLContentHandler.shared
        handler.deleteHTML(for: messageId)
        message.bodyStorageURI = tempURL.absoluteString

        try testStack.saveViewContext()

        let fetchedMessage = try XCTUnwrap(context.existingObject(with: message.objectID) as? Message)
        let displayable = fetchedMessage.displayableAttachments(
            using: builtHTMLAnalysis(for: fetchedMessage),
            hidingInlineReferencedInHTML: false
        )

        XCTAssertEqual(displayable.compactMap { $0.id }.sorted(), ["att-real-uri-file"])

        try? FileManager.default.removeItem(at: tempURL)
    }

    func testMessage_displayableAttachments_plainBubble_doesNotHideInlineForGenericDomainMention() throws {
        let messageId = "msg-inline-generic-domain-mention-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withAttachments()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-inline-body-image")
            .withFilename("image001.png")
            .withContentId("image001.png@01DCA5AF.35846080")
            .asImage(width: 220, height: 90)
            .withByteSize(192_520)
            .forMessage(message)
            .build(in: context)

        let handler = HTMLContentHandler.shared
        _ = handler.saveHTML(
            """
            <html><body>
            <div><img src="cid:image001.png@01DCA5AF.35846080" alt="hero"></div>
            <div>Warmly,</div>
            <div>Please see details at casatualife.com/events</div>
            </body></html>
            """,
            for: messageId
        )

        try testStack.saveViewContext()

        let fetchedMessage = try XCTUnwrap(context.existingObject(with: message.objectID) as? Message)
        let displayable = fetchedMessage.displayableAttachments(
            using: builtHTMLAnalysis(for: fetchedMessage),
            hidingInlineReferencedInHTML: false
        )

        XCTAssertEqual(displayable.compactMap { $0.id }.sorted(), ["att-inline-body-image"])

        handler.deleteHTML(for: messageId)
    }

    func testMessage_displayableAttachments_plainBubble_deduplicatesRepeatedInlineContentIDs() throws {
        let messageId = "msg-inline-duplicate-cid-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withAttachments()
            .build(in: context)

        for suffix in 1...3 {
            let _ = AttachmentBuilder()
                .withId("att-inline-dup-\(suffix)")
                .withFilename("IMG_6161.jpeg")
                .withContentId("6AFCA8C9-D2EF-4407-BD15-8D9F042220E9")
                .asImage(width: 1200, height: 1200)
                .withByteSize(350_000)
                .forMessage(message)
                .build(in: context)
        }

        let handler = HTMLContentHandler.shared
        _ = handler.saveHTML(
            """
            <html><body>
            <img src="cid:6AFCA8C9-D2EF-4407-BD15-8D9F042220E9" alt="IMG_6161.jpeg">
            <div><strong>RICK THAU</strong></div>
            <div>Carmel, CA</div>
            </body></html>
            """,
            for: messageId
        )

        try testStack.saveViewContext()

        let fetchedMessage = try XCTUnwrap(context.existingObject(with: message.objectID) as? Message)
        let displayable = fetchedMessage.displayableAttachments(
            using: builtHTMLAnalysis(for: fetchedMessage),
            hidingInlineReferencedInHTML: false
        )

        XCTAssertEqual(displayable.count, 1)
        XCTAssertEqual(displayable.first?.contentId, "6AFCA8C9-D2EF-4407-BD15-8D9F042220E9")

        handler.deleteHTML(for: messageId)
    }

    func testMessage_displayableAttachments_plainBubble_deduplicatesRepeatedRegularFiles() throws {
        let message = MessageBuilder()
            .withId("msg-duplicate-regular-files-\(UUID().uuidString)")
            .withAttachments()
            .build(in: context)

        for suffix in 1...2 {
            let _ = AttachmentBuilder()
                .withId("att-invoice-dup-\(suffix)")
                .withFilename("Invoice-4B07C32C-0025.pdf")
                .withMimeType("application/pdf")
                .withByteSize(91_248)
                .forMessage(message)
                .build(in: context)
        }

        for suffix in 1...2 {
            let _ = AttachmentBuilder()
                .withId("att-receipt-dup-\(suffix)")
                .withFilename("Receipt-2243-8647-5708.pdf")
                .withMimeType("application/pdf")
                .withByteSize(88_032)
                .forMessage(message)
                .build(in: context)
        }

        try testStack.saveViewContext()

        let fetchedMessage = try XCTUnwrap(context.existingObject(with: message.objectID) as? Message)
        let displayable = fetchedMessage.displayableAttachments(
            using: builtHTMLAnalysis(for: fetchedMessage),
            hidingInlineReferencedInHTML: false
        )

        XCTAssertEqual(displayable.count, 2)
        XCTAssertEqual(displayable.map(\.filename).sorted(), [
            "Invoice-4B07C32C-0025.pdf",
            "Receipt-2243-8647-5708.pdf"
        ])
    }

    // MARK: - Local Attachment Tests

    func testAttachment_isLocalAttachment_detectsLocalIds() throws {
        // Local attachments have IDs starting with "local_" (underscore, not hyphen)
        let localAttachment = AttachmentBuilder()
            .withId("local_uuid-123")
            .build(in: context)

        XCTAssertTrue(localAttachment.isLocalAttachment)

        let remoteAttachment = AttachmentBuilder()
            .withId("gmail-attachment-456")
            .build(in: context)

        XCTAssertFalse(remoteAttachment.isLocalAttachment)
    }

    // MARK: - Batch Size Tests

    func testFetchAttachments_usesBatchSize() throws {
        try context.performAndWait {
            // Create many attachments
            for i in 0..<100 {
                let _ = AttachmentBuilder()
                    .withId("att-\(i)")
                    .queued()
                    .build(in: context)
            }

            try context.save()

            // Fetch with batch size (like AttachmentDownloader does)
            let request = Attachment.fetchRequest()
            request.predicate = NSPredicate(format: "stateRaw == %@", "queued")
            request.fetchBatchSize = 10

            // Keep the fetched managed objects scoped to their context queue;
            // releasing a large batch off-queue can race Core Data's async
            // reference-queue cleanup during XCTest teardown.
            let results = try context.fetch(request)
            XCTAssertEqual(results.count, 100)
        }
    }

    // MARK: - Cleanup Tests

    func testCollectingValidFilePaths_fromAttachments() throws {
        // Create attachments with file paths
        let _ = AttachmentBuilder()
            .withId("att-1")
            .downloaded()
            .withLocalURL("Attachments/file1.jpg")
            .withPreviewURL("Previews/file1.jpg")
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-2")
            .downloaded()
            .withLocalURL("Attachments/file2.pdf")
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-3")
            .queued() // No files yet
            .build(in: context)

        try testStack.saveViewContext()

        // Collect valid file paths (like cleanupOrphanedFiles does)
        let request = Attachment.fetchRequest()
        let attachments = try context.fetch(request)

        let validFiles = Set(attachments.compactMap { attachment -> [String] in
            var files: [String] = []
            if let localURL = attachment.localURL {
                files.append(localURL)
            }
            if let previewURL = attachment.previewURL {
                files.append(previewURL)
            }
            return files
        }.flatMap { $0 })

        XCTAssertEqual(validFiles.count, 3)
        XCTAssertTrue(validFiles.contains("Attachments/file1.jpg"))
        XCTAssertTrue(validFiles.contains("Previews/file1.jpg"))
        XCTAssertTrue(validFiles.contains("Attachments/file2.pdf"))
    }

    private func fetchAttachmentState(
        objectID: NSManagedObjectID
    ) async throws -> (
        state: Attachment.State,
        lastDownloadFailedAt: Date?,
        localURL: String?,
        previewURL: String?
    ) {
        try await testStack.performBackgroundTask { context in
            guard let attachment = try context.existingObject(with: objectID) as? Attachment else {
                throw NSError(domain: "AttachmentDownloaderTests", code: 1)
            }
            return (
                attachment.state,
                attachment.lastDownloadFailedAt,
                attachment.localURL,
                attachment.previewURL
            )
        }
    }

    private func makeSynthesizedInlineMessage(
        messageID: String,
        data: Data,
        partID: String,
        filename: String,
        mimeType: String,
        contentID: String
    ) -> (attachmentID: String, message: GmailMessage) {
        let attachmentID = AttachmentPaths.synthesizedInlineAttachmentID(
            partId: partID,
            trimmedFilename: filename,
            mimeType: mimeType,
            contentId: contentID,
            size: data.count
        )
        let encodedData = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let part = MessagePart(
            partId: partID,
            mimeType: mimeType,
            filename: filename,
            headers: [
                MessageHeader(name: "Content-ID", value: "<\(contentID)>"),
                MessageHeader(name: "Content-Disposition", value: "inline")
            ],
            body: MessageBody(
                size: data.count,
                data: encodedData,
                attachmentId: nil
            ),
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

private actor SuspendedMessageRequest {
    private let message: GmailMessage
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(message: GmailMessage) {
        self.message = message
    }

    func perform() async -> GmailMessage {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return message
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor SuspendedAttachmentRequest {
    enum Outcome: Sendable {
        case success(Data)
        case failure
    }

    private let outcome: Outcome
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var observedCancellation = false

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func perform() async throws -> Data {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        observedCancellation = Task.isCancelled

        switch outcome {
        case .success(let data):
            return data
        case .failure:
            throw APIError.serverError(503)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor MessageScopedAttachmentRequestGate {
    enum Outcome: Sendable {
        case success(Data)
        case failure
    }

    private let outcomes: [String: Outcome]
    private var startedMessageIDs = Set<String>()
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    init(outcomes: [String: Outcome]) {
        self.outcomes = outcomes
    }

    func perform(messageId: String) async throws -> Data {
        startedMessageIDs.insert(messageId)
        let readyWaiters = startWaiters.filter { startedMessageIDs.count >= $0.count }
        startWaiters.removeAll { startedMessageIDs.count >= $0.count }
        readyWaiters.forEach { $0.continuation.resume() }

        await withCheckedContinuation { continuation in
            releaseWaiters[messageId] = continuation
        }

        switch outcomes[messageId] {
        case .success(let data):
            return data
        case .failure:
            throw APIError.serverError(503)
        case nil:
            throw APIError.notFound("Unconfigured message \(messageId)")
        }
    }

    func waitUntilStarted(count: Int) async {
        guard startedMessageIDs.count < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func release(messageId: String) {
        releaseWaiters.removeValue(forKey: messageId)?.resume()
    }
}

private final class AttachmentCleanupFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private final class SynchronousCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
