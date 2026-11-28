import XCTest
import CoreData
@testable import esc_chatmail

/// A received attachment downloads to a file, on a session of its own, and is decoded a chunk at
/// a time (architecture review 2026-11, attachments-storage-disk#2, networking#2). The transfer
/// is driven through the real `GmailAPIClient` and `StubURLProtocol`, since a mock says nothing
/// about the retry engine or status handling.
final class GmailAttachmentFileTransferTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        StubURLProtocol.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentFileTransfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    // MARK: - The decoder

    // Revert-check: the `\u` case of `GmailAttachmentBodyDecoder`'s `.inDataEscape`. Without it
    // a `=` written as `=`, as Google's JSON writers write it, refuses the whole response.
    func testDecoder_equalsDataBase64UrlEncoded_acrossSplitQuartetsAndEscapes() throws {
        var generator = SystemRandomNumberGenerator()
        let lengths = Array(0...70) + [1_000, 65_537, 200_003]
        for length in lengths {
            let bytes = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            let standard = bytes.base64EncodedString()
            let url = bytes.base64UrlEncodedString()
            let padded = standard
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
            let variants: [(json: String, encoded: String)] = [
                (#"{"size": \#(length), "data": "\#(url)"}"#, url),
                (#"{"data": "\#(padded.replacingOccurrences(of: "=", with: "\\u003d"))", "attachmentId": "a\"b", "size": \#(length)}"#, padded),
                (#"{"attachmentId": "x", "extra": {"a": [1, "}"]}, "data": "\#(standard.replacingOccurrences(of: "/", with: "\\/"))"}"#, standard)
            ]
            for (index, variant) in variants.enumerated() {
                let expected = try XCTUnwrap(Data(base64UrlEncoded: variant.encoded), "length \(length)")
                for chunkSize in [1, 3, 7, 64 * 1024] where length < 2_000 || chunkSize > 7 {
                    let decoded = try decode(variant.json, chunkSize: chunkSize)
                    XCTAssertEqual(decoded, expected, "length \(length), variant \(index), chunk \(chunkSize)")
                }
            }
        }
    }

    func testDecoder_refusesWhatIsNotAnAttachmentResponse() {
        let cases: [(json: String, error: GmailAttachmentBodyDecoder.DecodeError)] = [
            (#"{"size": 3}"#, .noDataField),
            (#"{"data": 12}"#, .malformedJSON),
            (#"[1, 2]"#, .malformedJSON),
            (#"{"data": "QUJ*"}"#, .invalidBase64),
            (#"{"data": "QUJDR"}"#, .invalidBase64),
            (#"{"data": "QU\nJD"}"#, .invalidBase64),
            (#"{"data": "QUJD="}"#, .invalidBase64),
            (#"{"data": "QUJD"#, .truncated),
            (#"{"data": "QUJD", "size""#, .truncated)
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(try decode(json, chunkSize: 4), json) { error in
                XCTAssertEqual(error as? GmailAttachmentBodyDecoder.DecodeError, expected, json)
            }
        }
    }

    func testDecoder_stopsWhenCancelled() throws {
        let source = directory.appendingPathComponent("response.json")
        try Data(#"{"data": "QUJDREVG"}"#.utf8).write(to: source)

        XCTAssertThrowsError(
            try GmailAttachmentBodyDecoder.decodeDataField(
                ofJSONFileAt: source,
                into: directory.appendingPathComponent("out"),
                chunkSize: 4,
                isCancelled: { true }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - The transfer session

    // Revert-check: `createTransferSession(basedOn:)` in `GmailAPIClient.init`. Use `session` for
    // the transfer and its 60 s cap and connectivity wait come back.
    func testTransferSession_isDerivedFromTheReadSession_withItsOwnLimits() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let client = GmailAPIClient(tokenManager: MockTokenManager(), session: URLSession(configuration: configuration))

        let transfer = client.transferSession.configuration
        XCTAssertTrue(transfer.protocolClasses?.contains { $0 == StubURLProtocol.self } == true)
        XCTAssertFalse(transfer.waitsForConnectivity)
        XCTAssertEqual(transfer.timeoutIntervalForRequest, NetworkConfig.attachmentTransferIdleTimeout)
        XCTAssertEqual(transfer.timeoutIntervalForResource, NetworkConfig.attachmentTransferResourceTimeout)
        XCTAssertNil(transfer.identifier, "Never a background session")
        XCTAssertLessThan(
            NetworkConfig.attachmentTransferResourceTimeout,
            AttachmentDownloader.orphanSweepRecentFileGracePeriod
        )
        // The read and send sessions keep their own.
        XCTAssertTrue(client.session.configuration.waitsForConnectivity)
        XCTAssertEqual(client.session.configuration.timeoutIntervalForResource, 60)
        XCTAssertEqual(client.sendSession.configuration.timeoutIntervalForResource, NetworkConfig.sendResourceTimeout)
    }

    // MARK: - downloadAttachmentFile

    // Revert-check: the `downloadFile` branch of `GmailAPIClient.performRetryingRequest`. Without
    // it the body arrives through `data(for:)`, nothing is moved to the response file, and the
    // decoder finds no response to read.
    func testDownloadAttachmentFile_returnsTheDecodedBytes_andKeepsOnlyThatFile() async throws {
        let bytes = Data((0..<50_000).map { UInt8($0 % 251) })
        StubURLProtocol.script = [.data(200, Self.response(for: bytes))]
        let client = makeClient()

        let file = try await client.downloadAttachmentFile(messageId: "m", attachmentId: "a", into: directory)

        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [file.lastPathComponent])
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testDownloadAttachmentFile_aMissingAttachment_isNotFound_andLeavesNothing() async throws {
        StubURLProtocol.script = [.data(404, Data(#"{"error": {"code": 404, "message": "Not Found"}}"#.utf8))]
        let client = makeClient()

        do {
            _ = try await client.downloadAttachmentFile(messageId: "m", attachmentId: "a", into: directory)
            XCTFail("Expected notFound")
        } catch APIError.notFound {
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testDownloadAttachmentFile_anUndecodableBody_isInvalidData_andLeavesNothing() async throws {
        StubURLProtocol.script = [.data(200, Data(#"{"size": 3}"#.utf8))]
        let client = makeClient()

        do {
            _ = try await client.downloadAttachmentFile(messageId: "m", attachmentId: "a", into: directory)
            XCTFail("Expected invalidData")
        } catch APIError.invalidData {
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testDownloadAttachmentFile_aTimedOutTransfer_isTheClientsRetries_andLeavesNothing() async throws {
        StubURLProtocol.script = [.error(URLError(.timedOut))]
        let client = makeClient()

        do {
            _ = try await client.downloadAttachmentFile(messageId: "m", attachmentId: "a", into: directory)
            XCTFail("Expected the timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 3, "The retry engine's three attempts")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testDownloadAttachmentFile_cancelledWhileItTransfers_leavesNothing() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let body = Self.response(for: Data("bytes".utf8))
        StubURLProtocol.responder = { _ in
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            return .data(200, body)
        }
        let client = makeClient()
        let directory = self.directory!

        let transfer = Task {
            try await client.downloadAttachmentFile(messageId: "m", attachmentId: "a", into: directory)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = started.wait(timeout: .now() + 5)
                continuation.resume()
            }
        }
        transfer.cancel()
        release.signal()

        let result = await transfer.result
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    // MARK: - Review fixes

    func testDecoder_anEscapedQuoteInAKey_isNotTheDataKey() throws {
        XCTAssertEqual(try decode(#"{"a\"data": "QQ", "data": "QUJD"}"#, chunkSize: 3), Data("ABC".utf8))
    }

    // Revert-check: the `statedSize` comparison in `GmailAttachmentBodyDecoder.decodeDataField`.
    // Without it a response whose bytes are not as many as its own `size` is taken as the file.
    func testDecoder_bytesThatAreNotAsManyAsTheStatedSize_areRefused() {
        XCTAssertThrowsError(try decode(#"{"size": 5, "data": "QUJD"}"#, chunkSize: 4)) { error in
            XCTAssertEqual(error as? GmailAttachmentBodyDecoder.DecodeError, .sizeMismatch)
        }
        XCTAssertEqual(try? decode(#"{"size" : 3 , "data": "QUJD"}"#, chunkSize: 2), Data("ABC".utf8))
    }

    // Revert-check: the `.truncated` case in `GmailAPIClient.downloadAttachmentFile`'s decode.
    // Without it a body cut short is `invalidData`, which reads as the sender's undecodable bytes.
    func testDownloadAttachmentFile_aBodyCutShort_isANetworkError_andLeavesNothing() async throws {
        StubURLProtocol.script = [.data(200, Data(#"{"size": 3, "data": "QUJD"#.utf8))]
        let client = makeClient()

        do {
            _ = try await client.downloadAttachmentFile(messageId: "m", attachmentId: "a", into: directory)
            XCTFail("Expected a network error")
        } catch APIError.networkError {
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testDownloadAttachmentFile_aRefreshedTokenAfterA401_downloads() async throws {
        let bytes = Data("after the refresh".utf8)
        StubURLProtocol.script = [.status(401), .data(200, Self.response(for: bytes))]
        let client = makeClient()

        let file = try await client.downloadAttachmentFile(messageId: "m", attachmentId: "a", into: directory)

        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testDownloadAttachmentFile_aServerErrorThenSuccess_keepsOnlyTheLastAttemptsBytes() async throws {
        let bytes = Data((0..<10_000).map { UInt8($0 % 200) })
        StubURLProtocol.script = [.data(503, Data("unavailable".utf8)), .data(200, Self.response(for: bytes))]
        let client = makeClient()

        let file = try await client.downloadAttachmentFile(messageId: "m", attachmentId: "a", into: directory)

        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [file.lastPathComponent])
    }

    // Revert-check: the `DownloadFileWriteError` rethrow in the catch of
    // `GmailAPIClient.performRetryingRequest`. Without it the file's own error leaves wrapped, so
    // a full disk (here a directory that is not there, a write failing the same way) cannot be
    // classified by the downloader (`StorageErrorClassifier.isOutOfSpace`), which then marks the
    // row failed. The file is never fetched again either way: one request.
    func testDownloadAttachmentFile_whoseFileCannotBeWritten_isNotRetried_andThrowsTheFilesError() async throws {
        StubURLProtocol.script = [.data(200, Self.response(for: Data("bytes".utf8)))]
        let client = makeClient()
        let missing = directory.appendingPathComponent("not-there", isDirectory: true)

        do {
            _ = try await client.downloadAttachmentFile(messageId: "m", attachmentId: "a", into: missing)
            XCTFail("Expected the write to fail")
        } catch {
            XCTAssertFalse(error is URLError)
            XCTAssertFalse(error is GmailAPIClient.DownloadFileWriteError, "The file's own error, unwrapped")
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    // The kill case: a transfer's file left by an earlier process (`incoming_…` in
    // `Attachments`, where the stream writes it) is removed by the next orphan sweep once its
    // grace period has passed, as every account file is; a sign-out takes `Attachments` out of
    // use whole. Before the stream, `download(for:)` left it in URLSession's temporary file,
    // which nothing removed. HONEST SCOPE: a kill cannot be made inside a test; this pins only
    // that the file the stream leaves is one the sweep removes.
    @MainActor
    func testAKilledTransfersFile_isRemovedByTheNextOrphanSweep() async throws {
        AttachmentPaths.setupDirectories()
        let attachments = try XCTUnwrap(AttachmentPaths.fullURL(for: AttachmentPaths.attachmentsFolder))
        let leftover = attachments.appendingPathComponent("incoming_\(UUID().uuidString).json")
        try Data(#"{"data": "QUJD"#.utf8).write(to: leftover)
        let stale = Date().addingTimeInterval(-2 * AttachmentDownloader.orphanSweepRecentFileGracePeriod)
        try FileManager.default.setAttributes(
            [.modificationDate: stale, .creationDate: stale],
            ofItemAtPath: leftover.path
        )
        let stack = TestCoreDataStack()
        let downloader = AttachmentDownloader(
            apiClient: MockGmailAPIClient(),
            coreDataStack: CoreDataStack(persistentContainerForTesting: stack.persistentContainer),
            fetchAttachmentFileReferences: { _ in [] }
        )

        await downloader.cleanupOrphanedFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    @MainActor
    func testCancelAndAwaitAllDownloads_whileATransferRuns_leavesNoStagedFile() async throws {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        AttachmentPaths.setupDirectories()
        let attachments = try XCTUnwrap(AttachmentPaths.fullURL(for: AttachmentPaths.attachmentsFolder))
        let stagedBefore = try Set(FileManager.default.contentsOfDirectory(atPath: attachments.path).filter { $0.hasPrefix("incoming_") })
        let messageID = "transfer-cancel-\(UUID().uuidString)"
        let message = MessageBuilder().withId(messageID).withAttachments().build(in: context)
        let attachment = AttachmentBuilder()
            .withId("transfer-cancel-attachment")
            .withFilename("large.pdf")
            .withMimeType("application/pdf")
            .withByteSize(4_096)
            .queued()
            .forMessage(message)
            .build(in: context)
        try context.save()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let body = Self.response(for: Data("bytes".utf8))
        StubURLProtocol.responder = { _ in
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            return .data(200, body)
        }
        let downloader = AttachmentDownloader(
            apiClient: makeClient(),
            coreDataStack: CoreDataStack(persistentContainerForTesting: stack.persistentContainer),
            availableStorageBytes: { nil }
        )
        let backgroundContext = stack.newBackgroundContext()

        let download = Task {
            await downloader.downloadAttachment(attachmentObjectID: attachment.objectID, messageId: messageID, in: backgroundContext)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = started.wait(timeout: .now() + 5)
                continuation.resume()
            }
        }
        await downloader.cancelAndAwaitAllDownloads()
        release.signal()
        await download.value
        XCTAssertTrue(downloader.reopenAdmission())

        let stagedAfter = try Set(FileManager.default.contentsOfDirectory(atPath: attachments.path).filter { $0.hasPrefix("incoming_") })
        XCTAssertEqual(stagedAfter, stagedBefore)
    }

    // MARK: - The downloader

    // HONEST SCOPE: the downloader's own retry loop is already gone (phase A); this pins that the
    // file path added none, against the real client: one download is the engine's three
    // attempts, never nine.
    @MainActor
    func testDownloader_aTimedOutAttachment_costsTheClientsAttemptsOnly_andEndsFailed() async throws {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        AttachmentPaths.setupDirectories()
        let messageID = "transfer-timeout-\(UUID().uuidString)"
        let message = MessageBuilder().withId(messageID).withAttachments().build(in: context)
        let attachment = AttachmentBuilder()
            .withId("transfer-timeout-attachment")
            .withFilename("large.pdf")
            .withMimeType("application/pdf")
            .withByteSize(4_096)
            .queued()
            .forMessage(message)
            .build(in: context)
        try context.save()
        StubURLProtocol.script = [.error(URLError(.timedOut))]
        let downloader = AttachmentDownloader(
            apiClient: makeClient(),
            coreDataStack: CoreDataStack(persistentContainerForTesting: stack.persistentContainer),
            availableStorageBytes: { nil }
        )

        await downloader.downloadAttachment(
            attachmentObjectID: attachment.objectID,
            messageId: messageID,
            in: stack.newBackgroundContext()
        )

        XCTAssertEqual(StubURLProtocol.requestCount, 3)
        let state = try await stack.performBackgroundTask { background in
            (try background.existingObject(with: attachment.objectID) as? Attachment)?.state
        }
        XCTAssertEqual(state, .failed)
    }

    // Revert-check: the `StorageErrorClassifier.isOutOfSpace(error)` branch of the downloader's
    // `catch`. Without it a download whose response or decoded file found no room marks the row
    // failed.
    @MainActor
    func testDownloader_aTransferThatFillsTheDisk_leavesTheRowQueued() async throws {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        AttachmentPaths.setupDirectories()
        let messageID = "transfer-full-\(UUID().uuidString)"
        let message = MessageBuilder().withId(messageID).withAttachments().build(in: context)
        let attachment = AttachmentBuilder()
            .withId("transfer-full-attachment")
            .withFilename("photo.png")
            .withMimeType("image/png")
            .withByteSize(4_096)
            .queued()
            .forMessage(message)
            .build(in: context)
        try context.save()
        let apiClient = MockGmailAPIClient()
        apiClient.getAttachmentError = CocoaError(.fileWriteOutOfSpace)
        let downloader = AttachmentDownloader(
            apiClient: apiClient,
            coreDataStack: CoreDataStack(persistentContainerForTesting: stack.persistentContainer),
            availableStorageBytes: { nil }
        )

        await downloader.downloadAttachment(
            attachmentObjectID: attachment.objectID,
            messageId: messageID,
            in: stack.newBackgroundContext()
        )

        let row = try await stack.performBackgroundTask { background in
            let stored = try background.existingObject(with: attachment.objectID) as? Attachment
            return (stored?.state, stored?.lastDownloadFailedAt)
        }
        XCTAssertEqual(row.0, .queued)
        XCTAssertNil(row.1)
    }

    // MARK: - Helpers

    private func decode(_ json: String, chunkSize: Int) throws -> Data {
        let source = directory.appendingPathComponent("response-\(UUID().uuidString).json")
        let destination = directory.appendingPathComponent("decoded-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try Data(json.utf8).write(to: source)
        try GmailAttachmentBodyDecoder.decodeDataField(
            ofJSONFileAt: source,
            into: destination,
            chunkSize: chunkSize,
            isCancelled: { false }
        )
        return try Data(contentsOf: destination)
    }

    private func makeClient() -> GmailAPIClient {
        GmailAPIClient(
            tokenManager: MockTokenManager(),
            retryStrategy: NetworkRetryStrategy(maxRetries: 3, initialDelay: 0.01, maxDelay: 0.02),
            session: StubURLProtocol.makeSession()
        )
    }

    private static func response(for bytes: Data) -> Data {
        Data(#"{"size": \#(bytes.count), "data": "\#(bytes.base64UrlEncodedString())"}"#.utf8)
    }
}
