import XCTest
import CoreData
import UniformTypeIdentifiers
@testable import esc_chatmail

/// A preview that is its original's own bytes is stored as a clone of the original's file, not
/// written a second time (architecture review 2026-11, attachments-storage-disk#3, the
/// clone-not-copy preview).
final class AttachmentPreviewCloneTests: XCTestCase {
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

    // MARK: - ImageProcessor.preview

    func testPreview_ofAnImageWithinTheLimit_isTheOriginal_andOfALargerOneIsEncoded() throws {
        let small = try TestImageData.encoded(as: .png, pixelSizes: [CGSize(width: 40, height: 30)])
        let large = try TestImageData.encoded(as: .png, pixelSizes: [CGSize(width: 2_000, height: 1_000)])

        XCTAssertEqual(ImageProcessor.preview(from: small, mimeType: "image/png"), .original)
        guard case .encoded(let bytes)? = ImageProcessor.preview(from: large, mimeType: "image/png") else {
            return XCTFail("A 2,000 px image's preview is a downsampled JPEG")
        }
        XCTAssertEqual(TestImageData.pixelSizes(of: bytes).first.map { max($0.width, $0.height) }, 1_600)
        XCTAssertNil(ImageProcessor.preview(from: Data("not an image".utf8), mimeType: "image/png"))
        XCTAssertNil(ImageProcessor.preview(from: small, mimeType: "application/zip"))
    }

    func testGenerateThumbnail_stillAnswersTheOriginalsBytes_forThePickersThatWriteThem() throws {
        let small = try TestImageData.encoded(as: .png, pixelSizes: [CGSize(width: 40, height: 30)])

        XCTAssertEqual(ImageProcessor.generateThumbnail(from: small, mimeType: "image/png"), small)
    }

    // MARK: - AttachmentPaths.storeClone

    // Revert-check: the `clonefile` call in `AttachmentPaths.storeClone`, replaced by a write of
    // the source's bytes (`Data(contentsOf:)`, then `write(to:)`), which is what a preview was:
    // the destination then shares no blocks. HONEST SCOPE: replaced by `FileManager.copyItem`
    // it still passes, because that copy clones on APFS as well (measured, iOS 27.0 simulator).
    func testStoreClone_storesTheSourcesBytes_asAFileThatSharesItsBlocks() throws {
        let source = try storeFile(Data(repeating: 0xAB, count: 256 * 1024), named: "source")
        let destination = AttachmentPaths.previewPath(idOrUUID: "clone-destination-\(UUID().uuidString)")
        pathsToRemove.append(destination)

        XCTAssertEqual(AttachmentPaths.storeClone(ofFileAt: source, at: destination), .saved)

        XCTAssertEqual(AttachmentPaths.loadData(from: destination), AttachmentPaths.loadData(from: source))
        let destinationURL = try XCTUnwrap(AttachmentPaths.fullURL(for: destination))
        XCTAssertEqual(APFSCloneProbe.mayShareBlocks(destinationURL), true)
    }

    // Revert-check: the `setAttributes([.modificationDate: Date()], …)` on the staging file in
    // `AttachmentPaths.storeClone`. Without it the clone keeps its older original's date, and
    // the orphan sweep's grace period reads a preview made now as one made then.
    func testStoreClone_ofAnOlderFile_isDatedNow() throws {
        let source = try storeFile(Data("older original".utf8), named: "dated-source")
        let sourceURL = try XCTUnwrap(AttachmentPaths.fullURL(for: source))
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: sourceURL.path)
        let destination = AttachmentPaths.previewPath(idOrUUID: "clone-dated-\(UUID().uuidString)")
        pathsToRemove.append(destination)
        let before = Date().addingTimeInterval(-1)

        XCTAssertEqual(AttachmentPaths.storeClone(ofFileAt: source, at: destination), .saved)

        let destinationURL = try XCTUnwrap(AttachmentPaths.fullURL(for: destination))
        let modified = try XCTUnwrap(
            try destinationURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        XCTAssertGreaterThanOrEqual(modified, before)
    }

    func testStoreClone_replacesAFileAlreadyThere_andLeavesNoStagingFile() throws {
        let source = try storeFile(Data("new preview".utf8), named: "replacing-source")
        let destination = AttachmentPaths.previewPath(idOrUUID: "clone-replaced-\(UUID().uuidString)")
        pathsToRemove.append(destination)
        XCTAssertTrue(AttachmentPaths.saveData(Data("old preview".utf8), to: destination))

        XCTAssertEqual(AttachmentPaths.storeClone(ofFileAt: source, at: destination), .saved)

        XCTAssertEqual(AttachmentPaths.loadData(from: destination), Data("new preview".utf8))
        let previews = try XCTUnwrap(AttachmentPaths.fullURL(for: AttachmentPaths.previewsFolder))
        let staging = try FileManager.default.contentsOfDirectory(atPath: previews.path)
            .filter { $0.hasPrefix(".clone-") }
        XCTAssertEqual(staging, [])
    }

    func testStoreClone_ofAMissingSource_isFailed_andMakesNoDestination() throws {
        let destination = AttachmentPaths.previewPath(idOrUUID: "clone-missing-\(UUID().uuidString)")

        let result = AttachmentPaths.storeClone(
            ofFileAt: AttachmentPaths.originalPath(idOrUUID: "missing-\(UUID().uuidString)", ext: "png"),
            at: destination
        )

        XCTAssertEqual(result, .failed)
        let destinationURL = try XCTUnwrap(AttachmentPaths.fullURL(for: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    // MARK: - Where previews are stored

    // Revert-check: the `.original` case in `AttachmentDownloader.performAttachmentDownload`.
    // Write the original's bytes through `writeAttachmentData` as before and no clone is made.
    @MainActor
    func testDownload_ofAnImageThatIsItsOwnPreview_storesThePreviewAsACloneOfTheOriginal() async throws {
        let png = try TestImageData.encoded(as: .png, pixelSizes: [CGSize(width: 40, height: 30)])
        let fixture = try makeQueuedImage(data: png, filename: "photo.png", mimeType: "image/png")
        let calls = WriterCalls()
        let downloader = makeDownloader(fixture: fixture, calls: calls)

        await downloader.downloadAttachment(
            attachmentObjectID: fixture.objectID,
            messageId: fixture.messageID,
            in: testStack.newBackgroundContext()
        )

        XCTAssertEqual(calls.clones, [[fixture.originalPath, fixture.previewPath]])
        XCTAssertEqual(calls.writes, [], "The original is the downloaded file, moved; the preview its clone")
        let row = try await fetchRow(fixture.objectID)
        XCTAssertEqual(row.previewURL, fixture.previewPath)
        XCTAssertEqual(AttachmentPaths.loadData(from: fixture.previewPath), png)
        let previewURL = try XCTUnwrap(AttachmentPaths.fullURL(for: fixture.previewPath))
        XCTAssertEqual(APFSCloneProbe.mayShareBlocks(previewURL), true)
    }

    @MainActor
    func testDownload_ofAnImagePastTheLimit_writesItsDownsampledPreview() async throws {
        let png = try TestImageData.encoded(as: .png, pixelSizes: [CGSize(width: 2_000, height: 1_000)])
        let fixture = try makeQueuedImage(data: png, filename: "large.png", mimeType: "image/png")
        let calls = WriterCalls()
        let downloader = makeDownloader(fixture: fixture, calls: calls)

        await downloader.downloadAttachment(
            attachmentObjectID: fixture.objectID,
            messageId: fixture.messageID,
            in: testStack.newBackgroundContext()
        )

        XCTAssertEqual(calls.clones, [])
        XCTAssertEqual(calls.writes, [fixture.previewPath])
        let row = try await fetchRow(fixture.objectID)
        XCTAssertEqual(row.previewURL, fixture.previewPath)
    }

    // Revert-check: the `.original` case in `SynthesizedInlineAttachmentRecovery.recover`. Write
    // the part's bytes through `writeData` as before and no clone is made.
    @MainActor
    func testSynthesizedInlineRecovery_ofAnImagePart_storesThePreviewAsAClone() async throws {
        let png = try TestImageData.encoded(as: .png, pixelSizes: [CGSize(width: 40, height: 30)])
        let messageID = "clone-recovery-\(UUID().uuidString)"
        let recovered = makeSynthesizedInlineImageMessage(messageID: messageID, png: png)
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
        let calls = WriterCalls()
        let downloader = AttachmentDownloader(
            apiClient: apiClient,
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            availableStorageBytes: { nil },
            writeAttachmentData: { data, path in
                calls.recordWrite(path)
                return AttachmentPaths.writeData(data, to: path)
            },
            storeAttachmentClone: { source, destination in
                calls.recordClone(source, destination)
                return AttachmentPaths.storeClone(ofFileAt: source, at: destination)
            }
        )

        await downloader.downloadAttachment(
            attachmentObjectID: attachment.objectID,
            messageId: messageID,
            in: testStack.newBackgroundContext()
        )

        XCTAssertEqual(calls.clones, [[originalPath, previewPath]])
        XCTAssertEqual(calls.writes, [originalPath])
        let row = try await fetchRow(attachment.objectID)
        XCTAssertEqual(row.previewURL, previewPath)
    }

    // Revert-check: the `.original` case in `MessagePersister.persistInlineAttachmentData`.
    // Save the bytes again with `saveData` and the stored preview shares no blocks.
    @MainActor
    func testInlinePartStoredWithItsMessage_storesItsPreviewAsAClone() async throws {
        let png = try TestImageData.encoded(as: .png, pixelSizes: [CGSize(width: 40, height: 30)])
        let messageID = "clone-inline-\(UUID().uuidString)"
        var headers = ProcessedHeaders()
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        let processed = ProcessedMessage(
            id: messageID,
            gmThreadId: "thread-\(messageID)",
            snippet: "Image",
            cleanedSnippet: "Image",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Image",
            labelIds: ["INBOX"],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: true,
            attachmentInfo: [
                AttachmentInfo(
                    id: "local_inline_clone_test",
                    filename: "inline.png",
                    mimeType: "image/png",
                    size: png.count,
                    contentId: "clone-inline",
                    inlineData: png
                )
            ]
        )

        try await MessagePersister(photoPrefetcher: { _ in }).createNewMessage(
            processed,
            labelIds: nil,
            myAliases: [normalizedEmail("recipient@example.com")],
            in: viewContext
        )

        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", messageID)
        let attachment = try XCTUnwrap(try viewContext.fetch(request).first?.attachmentsArray.first)
        let previewPath = try XCTUnwrap(attachment.previewURL)
        pathsToRemove.append(contentsOf: [previewPath, try XCTUnwrap(attachment.localURL)])
        XCTAssertEqual(AttachmentPaths.loadData(from: previewPath), png)
        XCTAssertEqual(APFSCloneProbe.mayShareBlocks(try XCTUnwrap(AttachmentPaths.fullURL(for: previewPath))), true)
    }

    // MARK: - Helpers

    private struct QueuedImage {
        let objectID: NSManagedObjectID
        let messageID: String
        let attachmentID: String
        let data: Data
        let originalPath: String
        let previewPath: String
    }

    @MainActor
    private func makeQueuedImage(data: Data, filename: String, mimeType: String) throws -> QueuedImage {
        let messageID = "clone-message-\(UUID().uuidString)"
        let attachmentID = "clone-attachment-\(UUID().uuidString)"
        let message = MessageBuilder().withId(messageID).withAttachments().build(in: viewContext)
        let attachment = AttachmentBuilder()
            .withId(attachmentID)
            .withFilename(filename)
            .withMimeType(mimeType)
            .withByteSize(Int64(data.count))
            .queued()
            .forMessage(message)
            .build(in: viewContext)
        try viewContext.save()
        let ext = (filename as NSString).pathExtension
        let fixture = QueuedImage(
            objectID: attachment.objectID,
            messageID: messageID,
            attachmentID: attachmentID,
            data: data,
            originalPath: AttachmentPaths.originalPath(messageId: messageID, attachmentId: attachmentID, ext: ext),
            previewPath: AttachmentPaths.previewPath(messageId: messageID, attachmentId: attachmentID)
        )
        pathsToRemove.append(contentsOf: [fixture.originalPath, fixture.previewPath])
        return fixture
    }

    @MainActor
    private func makeDownloader(fixture: QueuedImage, calls: WriterCalls) -> AttachmentDownloader {
        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses["\(fixture.messageID):\(fixture.attachmentID)"] = fixture.data
        return AttachmentDownloader(
            apiClient: apiClient,
            coreDataStack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            availableStorageBytes: { nil },
            writeAttachmentData: { data, path in
                calls.recordWrite(path)
                return AttachmentPaths.writeData(data, to: path)
            },
            storeAttachmentClone: { source, destination in
                calls.recordClone(source, destination)
                return AttachmentPaths.storeClone(ofFileAt: source, at: destination)
            }
        )
    }

    private func fetchRow(_ objectID: NSManagedObjectID) async throws -> (previewURL: String?, localURL: String?) {
        try await testStack.performBackgroundTask { context in
            guard let attachment = try context.existingObject(with: objectID) as? Attachment else {
                throw NSError(domain: "AttachmentPreviewCloneTests", code: 1)
            }
            return (attachment.previewURL, attachment.localURL)
        }
    }

    /// A message whose one inline part is a PNG, the synthesized `local_inline_` attachment the
    /// downloader recovers from the full message.
    private func makeSynthesizedInlineImageMessage(
        messageID: String,
        png: Data
    ) -> (attachmentID: String, message: GmailMessage) {
        let attachmentID = AttachmentPaths.synthesizedInlineAttachmentID(
            partId: "1.2",
            trimmedFilename: "inline.png",
            mimeType: "image/png",
            contentId: "clone@example.com",
            size: png.count
        )
        let encoded = png.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let part = MessagePart(
            partId: "1.2",
            mimeType: "image/png",
            filename: "inline.png",
            headers: [
                MessageHeader(name: "Content-ID", value: "<clone@example.com>"),
                MessageHeader(name: "Content-Disposition", value: "inline")
            ],
            body: MessageBody(size: png.count, data: encoded, attachmentId: nil),
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
                sizeEstimate: png.count
            )
        )
    }

    private func storeFile(_ data: Data, named name: String) throws -> String {
        let path = AttachmentPaths.originalPath(idOrUUID: "clone-\(name)-\(UUID().uuidString)", ext: "bin")
        XCTAssertTrue(AttachmentPaths.saveData(data, to: path))
        pathsToRemove.append(path)
        return path
    }
}

/// The paths the downloader's two writers were handed, recorded from its processing task.
private final class WriterCalls: @unchecked Sendable {
    /// Guarded by `lock`.
    private var storedWrites: [String] = []
    /// Guarded by `lock`.
    private var storedClones: [[String]] = []
    private let lock = NSLock()

    var writes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedWrites
    }

    var clones: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storedClones
    }

    func recordWrite(_ path: String) {
        lock.lock()
        storedWrites.append(path)
        lock.unlock()
    }

    func recordClone(_ source: String, _ destination: String) {
        lock.lock()
        storedClones.append([source, destination])
        lock.unlock()
    }
}
