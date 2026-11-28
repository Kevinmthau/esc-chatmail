import XCTest
import CoreData
import CoreGraphics
@testable import esc_chatmail

/// A download refused, or stopped, for want of space is shown, not silent, and leaves the row as
/// it was (attachments-storage-disk#5's review): the downloader publishes the refusal in memory
/// (`AttachmentDownloader.isRefusedForSpace`), the views show "Not enough storage" with a Retry
/// (`AttachmentDownloadIndicatorPolicy`), and neither Retry nor the redownload path writes
/// `queued` before the floor admits. Fixtures go through a main-queue context, and every test
/// that touches the downloader is `@MainActor`.
final class AttachmentSpaceRefusalTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!
    private var pathsToRemove: [String] = []

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        viewContext = MainActor.assumeIsolated { testStack.makeMainQueueViewContext() }
        AttachmentPaths.setupDirectories()
    }

    override func tearDown() {
        pathsToRemove.forEach { AttachmentPaths.deleteFile(at: $0) }
        pathsToRemove = []
        viewContext = nil
        testStack = nil
        super.tearDown()
    }

    // MARK: - Scenario A: a refusal is shown, and Retry asks the floor again

    // Revert-check: `recordSpaceRefusal` in `AttachmentDownloader.hasRoomToDownload`. Without it
    // a refused download is a dimmed placeholder with nothing to tap.
    @MainActor
    func testRefusedDownload_isPublished_andARetryWithRoomDownloadsAndClearsIt() async throws {
        let fixture = try makeRow(state: .queued, byteSize: 100 * 1024 * 1024)
        let space = SpaceBox(AttachmentDownloadSpacePolicy.floorBytes + 50 * 1024 * 1024)
        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses[fixture.responseKey] = fixture.data
        let downloader = makeDownloader(apiClient: apiClient, space: space)

        await downloader.downloadAttachmentIfNeeded(for: fixture.attachment)

        XCTAssertTrue(downloader.isRefusedForSpace(messageId: fixture.messageID, attachmentId: fixture.attachmentID))
        XCTAssertEqual(apiClient.getAttachmentCallCountSnapshot(), 0)
        let state1 = try await fetchState(fixture.objectID)
        XCTAssertEqual(state1, .queued)

        space.value = nil
        await downloader.retryFailedDownload(for: fixture.attachment)

        XCTAssertFalse(downloader.isRefusedForSpace(messageId: fixture.messageID, attachmentId: fixture.attachmentID))
        XCTAssertEqual(apiClient.getAttachmentCallCountSnapshot(), 1)
        let state2 = try await fetchState(fixture.objectID)
        XCTAssertEqual(state2, .downloaded)
    }

    // MARK: - Scenario B: Retry on a failed card

    // Revert-check: the `admitsByFreeSpace` guard in `AttachmentDownloader.performRetryFailedDownload`.
    // Without it Retry writes `queued` first, and the failed card's Retry turns into a placeholder.
    @MainActor
    func testRetryOfAFailedRow_thatTheFloorRefuses_leavesTheRowFailed() async throws {
        let fixture = try makeRow(state: .failed, byteSize: 100 * 1024 * 1024)
        let apiClient = MockGmailAPIClient()
        let downloader = makeDownloader(apiClient: apiClient, space: SpaceBox(0))

        await downloader.retryFailedDownload(for: fixture.attachment)

        let state3 = try await fetchState(fixture.objectID)

        XCTAssertEqual(state3, .failed)
        XCTAssertTrue(downloader.isRefusedForSpace(messageId: fixture.messageID, attachmentId: fixture.attachmentID))
        XCTAssertEqual(apiClient.getAttachmentCallCountSnapshot(), 0)
    }

    // Revert-check: the `admitsByFreeSpace` guard in
    // `AttachmentDownloader.performDownloadAttachmentIfNeeded`. Without it the redownload path
    // writes `queued` over a downloaded row whose file is gone, before the floor refuses.
    @MainActor
    func testRedownloadOfADownloadedRow_thatTheFloorRefuses_leavesTheRowDownloaded() async throws {
        let fixture = try makeRow(state: .downloaded, byteSize: 4_096, storesOriginal: false)
        XCTAssertTrue(fixture.attachment.needsRedownload)
        let downloader = makeDownloader(apiClient: MockGmailAPIClient(), space: SpaceBox(0))

        await downloader.downloadAttachmentIfNeeded(for: fixture.attachment)

        let state4 = try await fetchState(fixture.objectID)

        XCTAssertEqual(state4, .downloaded)
        XCTAssertTrue(downloader.isRefusedForSpace(messageId: fixture.messageID, attachmentId: fixture.attachmentID))
    }

    // MARK: - Scenario C: what the views show

    // Revert-check: the `local_inline_` exclusion in `AttachmentDownloadIndicatorPolicy.indicator`.
    // Without it a queued inline part shows the sending spinner for good, and a failed one no Retry.
    func testIndicator_ofAReceivedInlinePart_isNeverTheSendingSpinner() {
        func indicator(_ state: Attachment.State, id: String, refused: Bool = false) -> AttachmentDownloadIndicatorPolicy.Indicator {
            AttachmentDownloadIndicatorPolicy.indicator(
                state: state,
                attachmentId: id,
                isReady: state == .downloaded,
                isDownloading: false,
                isRefusedForSpace: refused
            )
        }
        XCTAssertEqual(indicator(.queued, id: "local_inline_part", refused: true), .refusedForSpace)
        XCTAssertEqual(indicator(.queued, id: "local_inline_part"), .notDownloaded)
        XCTAssertEqual(indicator(.failed, id: "local_inline_part"), .downloadFailed)
        XCTAssertEqual(indicator(.queued, id: "local_user_added"), .uploading)
        XCTAssertEqual(indicator(.failed, id: "local_user_added"), .uploadFailed)
        XCTAssertEqual(indicator(.failed, id: "remote-id", refused: true), .refusedForSpace)
        XCTAssertEqual(indicator(.downloaded, id: "remote-id"), .none)
        // Revert-check: `!isReady` in the refusal's condition. Without it a part a sibling's
        // recovery stored after its refusal shows "Not enough storage" over a ready image.
        XCTAssertEqual(indicator(.downloaded, id: "local_inline_part", refused: true), .none)
    }

    // MARK: - Out-of-space branches the first push left unpinned

    // Revert-check: the `guard previewWrite != .outOfSpace` after the PDF preview's write in
    // `AttachmentDownloader.performAttachmentDownload`. Without it the PDF is kept with no preview.
    @MainActor
    func testDownload_ofAPDFWhosePreviewFindsNoRoom_keepsNothing_andLeavesTheRowQueued() async throws {
        let pdf = try Self.onePagePDF()
        let fixture = try makeRow(state: .queued, byteSize: Int64(pdf.count), filename: "report.pdf", mimeType: "application/pdf", data: pdf)
        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses[fixture.responseKey] = pdf
        let previewPath = fixture.previewPath
        let downloader = makeDownloader(
            apiClient: apiClient,
            space: SpaceBox(nil),
            writeAttachmentData: { data, path in
                path == previewPath ? .outOfSpace : AttachmentPaths.writeData(data, to: path)
            }
        )

        await downloader.downloadAttachment(
            attachmentObjectID: fixture.objectID,
            messageId: fixture.messageID,
            in: testStack.newBackgroundContext()
        )

        let state5 = try await fetchState(fixture.objectID)

        XCTAssertEqual(state5, .queued)
        XCTAssertFalse(fileExists(fixture.originalPath))
    }

    // Revert-check: the `if outOfSpace, savedOriginal` removal in
    // `SynthesizedInlineAttachmentRecovery.recover`. Without it the part's original is kept while
    // its row is left without it.
    @MainActor
    func testInlineRecovery_whosePreviewFindsNoRoom_takesTheOriginalWithIt() async throws {
        let png = try TestImageData.encoded(as: .png, pixelSizes: [CGSize(width: 40, height: 30)])
        let messageID = "refusal-recovery-\(UUID().uuidString)"
        let recovered = Self.synthesizedInlineImageMessage(messageID: messageID, png: png)
        let message = MessageBuilder().withId(messageID).withAttachments().build(in: viewContext)
        let attachment = AttachmentBuilder()
            .withId(recovered.attachmentID)
            .withFilename("inline.png")
            .withMimeType("image/png")
            .withByteSize(Int64(png.count))
            .queued()
            .forMessage(message)
            .build(in: viewContext)
        try viewContext.save()
        let originalPath = AttachmentPaths.originalPath(messageId: messageID, attachmentId: recovered.attachmentID, ext: "png")
        let previewPath = AttachmentPaths.previewPath(messageId: messageID, attachmentId: recovered.attachmentID)
        pathsToRemove.append(contentsOf: [originalPath, previewPath])
        let apiClient = MockGmailAPIClient()
        apiClient.getMessageResponses[messageID] = recovered.message
        let downloader = makeDownloader(
            apiClient: apiClient,
            space: SpaceBox(nil),
            writeAttachmentData: { data, path in
                path == previewPath ? .outOfSpace : AttachmentPaths.writeData(data, to: path)
            },
            storeAttachmentClone: { source, destination in
                destination == previewPath ? .outOfSpace : AttachmentPaths.storeClone(ofFileAt: source, at: destination)
            }
        )

        await downloader.downloadAttachment(
            attachmentObjectID: attachment.objectID,
            messageId: messageID,
            in: testStack.newBackgroundContext()
        )

        XCTAssertFalse(fileExists(originalPath))
        // Revert-check: the `requestedFoundNoRoom` call in the recovery's persistence and the
        // `recordSpaceRefusal` after it in `AttachmentDownloader.recoverSynthesizedInlineAttachments`.
        // Without them the row stays queued with no badge and nothing to tap.
        XCTAssertTrue(downloader.isRefusedForSpace(messageId: messageID, attachmentId: recovered.attachmentID))
        let state6 = try await fetchState(attachment.objectID)
        XCTAssertEqual(state6, .queued)
    }

    // Revert-check: the `originalExistedBefore` branch of the out-of-space rollback in
    // `AttachmentDownloader.performAttachmentDownload`. Without it a download that finds no room
    // deletes the original the row already had on disk.
    @MainActor
    func testDownloadThatFindsNoRoom_leavesTheOriginalTheRowAlreadyHad() async throws {
        let fixture = try makeRow(state: .downloaded, byteSize: 4_096, storesOriginal: true, legacyPreview: true)
        XCTAssertTrue(fixture.attachment.needsRedownload, "A legacy preview path makes it download again")
        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses[fixture.responseKey] = fixture.data
        let previewPath = fixture.previewPath
        let downloader = makeDownloader(
            apiClient: apiClient,
            space: SpaceBox(nil),
            writeAttachmentData: { data, path in
                path == previewPath ? .outOfSpace : AttachmentPaths.writeData(data, to: path)
            },
            storeAttachmentClone: { source, destination in
                destination == previewPath ? .outOfSpace : AttachmentPaths.storeClone(ofFileAt: source, at: destination)
            }
        )

        await downloader.downloadAttachmentIfNeeded(for: fixture.attachment)

        XCTAssertTrue(fileExists(fixture.originalPath))
        XCTAssertEqual(AttachmentPaths.loadData(from: fixture.originalPath), fixture.data)
    }

    // Revert-check: summing the synthesized siblings in the `local_inline_` branch of
    // `AttachmentDownloader.performAttachmentDownload`. Ask about this row alone and a recovery
    // that writes both is admitted with room for one.
    @MainActor
    func testInlineRecoveryFloor_countsEverySynthesizedSiblingOfTheMessage() async throws {
        let messageID = "refusal-siblings-\(UUID().uuidString)"
        let message = MessageBuilder().withId(messageID).withAttachments().build(in: viewContext)
        let requested = AttachmentBuilder()
            .withId("local_inline_requested")
            .withFilename("a.png")
            .withMimeType("image/png")
            .withByteSize(60 * 1024 * 1024)
            .queued()
            .forMessage(message)
            .build(in: viewContext)
        _ = AttachmentBuilder()
            .withId("local_inline_sibling")
            .withFilename("b.png")
            .withMimeType("image/png")
            .withByteSize(60 * 1024 * 1024)
            .queued()
            .forMessage(message)
            .build(in: viewContext)
        try viewContext.save()
        let apiClient = MockGmailAPIClient()
        let downloader = makeDownloader(
            apiClient: apiClient,
            space: SpaceBox(AttachmentDownloadSpacePolicy.floorBytes + 100 * 1024 * 1024)
        )

        await downloader.downloadAttachment(
            attachmentObjectID: requested.objectID,
            messageId: messageID,
            in: testStack.newBackgroundContext()
        )

        XCTAssertEqual(apiClient.getMessageCallCountSnapshot(), 0, "120 MB of parts do not fit 100 MB of room")
        XCTAssertTrue(downloader.isRefusedForSpace(messageId: messageID, attachmentId: "local_inline_requested"))
    }

    // MARK: - The stored name's extension

    // Revert-check: `AttachmentExportPolicy.splitExtension` in `AttachmentPaths.storedFileExtension`.
    // Take the filename's `pathExtension` whole and a sender's 300-character extension is in the
    // stored name, longer than a file name can be.
    func testStoredFileExtension_isTheFilenamesOnlyWhereItIsAnExtension() {
        XCTAssertEqual(AttachmentPaths.storedFileExtension(filename: "Photo.JPG", mimeType: "image/jpeg"), "jpg")
        XCTAssertEqual(
            AttachmentPaths.storedFileExtension(filename: "x." + String(repeating: "a", count: 300), mimeType: "application/pdf"),
            "pdf"
        )
        XCTAssertEqual(AttachmentPaths.storedFileExtension(filename: "Report 2026.11.13", mimeType: "application/pdf"), "pdf")
        XCTAssertEqual(AttachmentPaths.storedFileExtension(filename: "notes", mimeType: "text/plain"), "txt")
    }

    // MARK: - Helpers

    private struct Row {
        let attachment: Attachment
        let objectID: NSManagedObjectID
        let messageID: String
        let attachmentID: String
        let data: Data
        let originalPath: String
        let previewPath: String
        var responseKey: String { "\(messageID):\(attachmentID)" }
    }

    @MainActor
    private func makeRow(
        state: Attachment.State,
        byteSize: Int64,
        filename: String = "photo.png",
        mimeType: String = "image/png",
        data: Data? = nil,
        storesOriginal: Bool = false,
        legacyPreview: Bool = false
    ) throws -> Row {
        let bytes = try data ?? TestImageData.encoded(as: .png, pixelSizes: [CGSize(width: 4, height: 4)])
        let messageID = "refusal-message-\(UUID().uuidString)"
        let attachmentID = "refusal-attachment-\(UUID().uuidString)"
        let ext = (filename as NSString).pathExtension
        let originalPath = AttachmentPaths.originalPath(messageId: messageID, attachmentId: attachmentID, ext: ext)
        let previewPath = AttachmentPaths.previewPath(messageId: messageID, attachmentId: attachmentID)
        pathsToRemove.append(contentsOf: [originalPath, previewPath])
        if storesOriginal {
            XCTAssertTrue(AttachmentPaths.saveData(bytes, to: originalPath))
        }
        let message = MessageBuilder().withId(messageID).withAttachments().build(in: viewContext)
        var builder = AttachmentBuilder()
            .withId(attachmentID)
            .withFilename(filename)
            .withMimeType(mimeType)
            .withByteSize(byteSize)
            .forMessage(message)
        switch state {
        case .downloaded:
            builder = builder.downloaded().withLocalURL(originalPath)
        case .failed:
            builder = builder.failed()
        default:
            builder = builder.queued()
        }
        if legacyPreview {
            builder = builder.withPreviewURL(AttachmentPaths.previewPath(idOrUUID: attachmentID))
        }
        let attachment = builder.build(in: viewContext)
        try viewContext.save()
        return Row(
            attachment: attachment,
            objectID: attachment.objectID,
            messageID: messageID,
            attachmentID: attachmentID,
            data: bytes,
            originalPath: originalPath,
            previewPath: previewPath
        )
    }

    @MainActor
    private func makeDownloader(
        apiClient: MockGmailAPIClient,
        space: SpaceBox,
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
            availableStorageBytes: { space.value },
            writeAttachmentData: writeAttachmentData,
            storeAttachmentClone: storeAttachmentClone
        )
    }

    private func fetchState(_ objectID: NSManagedObjectID) async throws -> Attachment.State? {
        try await testStack.performBackgroundTask { context in
            (try context.existingObject(with: objectID) as? Attachment)?.state
        }
    }

    private func fileExists(_ path: String) -> Bool {
        AttachmentPaths.fullURL(for: path).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    private static func onePagePDF() throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 300)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func synthesizedInlineImageMessage(messageID: String, png: Data) -> (attachmentID: String, message: GmailMessage) {
        let attachmentID = AttachmentPaths.synthesizedInlineAttachmentID(
            partId: "1.2",
            trimmedFilename: "inline.png",
            mimeType: "image/png",
            contentId: "refusal@example.com",
            size: png.count
        )
        let part = MessagePart(
            partId: "1.2",
            mimeType: "image/png",
            filename: "inline.png",
            headers: [
                MessageHeader(name: "Content-ID", value: "<refusal@example.com>"),
                MessageHeader(name: "Content-Disposition", value: "inline")
            ],
            body: MessageBody(size: png.count, data: png.base64UrlEncodedString(), attachmentId: nil),
            parts: nil
        )
        let payload = MessagePart(partId: "", mimeType: "multipart/related", filename: nil, headers: nil, body: nil, parts: [part])
        return (
            attachmentID,
            GmailMessage(
                id: messageID,
                threadId: "thread-\(messageID)",
                labelIds: ["INBOX"],
                snippet: nil,
                historyId: nil,
                internalDate: nil,
                payload: payload,
                sizeEstimate: png.count
            )
        )
    }
}

/// The free space a test's downloader reads, which the test changes between calls.
private final class SpaceBox: @unchecked Sendable {
    /// Guarded by `lock`.
    private var stored: Int64?
    private let lock = NSLock()

    init(_ value: Int64?) {
        stored = value
    }

    var value: Int64? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
