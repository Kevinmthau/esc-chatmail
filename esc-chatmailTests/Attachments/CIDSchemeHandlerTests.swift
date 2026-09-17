import XCTest
import WebKit
import CoreData
@testable import esc_chatmail

@MainActor
final class CIDSchemeHandlerTests: XCTestCase {
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

    func testNormalizedContentIDMatchesEmailDocumentBehavior() throws {
        let url = try XCTUnwrap(URL(string: "cid:///%3CLogo%40Example.COM%3E"))

        XCTAssertEqual(CIDSchemeHandler.normalizedContentID(from: url), "logo@example.com")
        XCTAssertEqual(
            CIDSchemeHandler.normalizedContentID(from: url),
            EmailDocument.normalizedContentID("cid:///%3CLogo%40Example.COM%3E")
        )
    }

    func testMissingCIDAttachmentRendersFallbackUntilAttachmentPersistsLocally() async throws {
        AttachmentPaths.setupDirectories()
        let message = MessageBuilder()
            .withId("message-cid-later-local")
            .withAttachments()
            .build(in: context)
        try testStack.saveViewContext()

        let stack = testStack!
        let apiClient = MockGmailAPIClient()
        let handler = CIDSchemeHandler(
            message: message,
            apiClient: apiClient,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        let cidURL = try XCTUnwrap(URL(string: "cid:later@example.com"))
        let transparentPixel = try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
        )

        let fallbackFinished = expectation(description: "missing cid scheme task finished with fallback")
        let fallbackTask = MockURLSchemeTask(url: cidURL) {
            fallbackFinished.fulfill()
        }

        handler.webView(WKWebView(), start: fallbackTask)

        await fulfillment(of: [fallbackFinished], timeout: 2.0)
        XCTAssertNil(fallbackTask.error)
        XCTAssertEqual(fallbackTask.response?.mimeType, "image/gif")
        XCTAssertEqual(fallbackTask.receivedData, transparentPixel)
        XCTAssertEqual(apiClient.getAttachmentCallCount, 0)

        let attachmentId = "att-cid-later-local"
        let localPath = AttachmentPaths.originalPath(
            messageId: message.id,
            attachmentId: attachmentId,
            ext: "png"
        )
        let localData = Data([0x89, 0x50, 0x4E, 0x47, 0x44])
        XCTAssertTrue(AttachmentPaths.saveData(localData, to: localPath))
        defer { AttachmentPaths.deleteFile(at: localPath) }

        _ = AttachmentBuilder()
            .withId(attachmentId)
            .withFilename("later.png")
            .withMimeType("image/png")
            .withContentId("later@example.com")
            .downloaded()
            .withLocalURL(localPath)
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let localFinished = expectation(description: "persisted local cid scheme task finished")
        let localTask = MockURLSchemeTask(url: cidURL) {
            localFinished.fulfill()
        }

        handler.webView(WKWebView(), start: localTask)

        await fulfillment(of: [localFinished], timeout: 2.0)
        XCTAssertNil(localTask.error)
        XCTAssertEqual(localTask.response?.mimeType, "image/png")
        XCTAssertEqual(localTask.receivedData, localData)
        XCTAssertEqual(apiClient.getAttachmentCallCount, 0)
    }

    func testOnDemandFallbackFetchesAndPersistsMissingInlineAttachment() async throws {
        let message = MessageBuilder()
            .withId("message-cid-fallback")
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId("att-cid-fallback")
            .withFilename("logo.png")
            .withMimeType("image/png")
            .withContentId("Logo@Example.COM")
            .queued()
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses["\(message.id):\(attachment.id!)"] = imageData

        let didFinish = expectation(description: "cid scheme task finished")
        let task = MockURLSchemeTask(
            url: try XCTUnwrap(URL(string: "cid:///%3Clogo%40example.com%3E")),
            didComplete: {
                didFinish.fulfill()
            }
        )
        let stack = testStack!
        let handler = CIDSchemeHandler(
            message: message,
            apiClient: apiClient,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )

        handler.webView(WKWebView(), start: task)

        await fulfillment(of: [didFinish], timeout: 2.0)
        XCTAssertNil(task.error)
        XCTAssertEqual(task.receivedData, imageData)
        XCTAssertEqual(apiClient.getAttachmentCallCount, 1)
        XCTAssertEqual(apiClient.getAttachmentCalls.first?.messageId, message.id)
        XCTAssertEqual(apiClient.getAttachmentCalls.first?.attachmentId, attachment.id)

        let verificationContext = testStack.newBackgroundContext()
        let persistedLocalURL: String? = await verificationContext.perform {
            let request = Attachment.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", "att-cid-fallback")
            request.fetchLimit = 1
            return try? verificationContext.fetch(request).first?.localURL
        }
        defer { AttachmentPaths.deleteFile(at: persistedLocalURL) }

        XCTAssertEqual(AttachmentPaths.loadData(from: persistedLocalURL), imageData)
        XCTAssertTrue(
            AttachmentPaths.usesRemoteIdentity(
                persistedLocalURL,
                messageId: message.id,
                attachmentId: attachment.id!
            )
        )
    }

    func testOnDemandFallbackFailureRefreshesFailedTimestamp() async throws {
        let staleFailureDate = Date().addingTimeInterval(-3_600)
        let message = MessageBuilder()
            .withId("message-cid-fallback-failure")
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId("att-cid-fallback-failure")
            .withFilename("missing.png")
            .withMimeType("image/png")
            .withContentId("missing@example.com")
            .failed()
            .withLastDownloadFailedAt(staleFailureDate)
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let apiClient = MockGmailAPIClient()
        let didFinish = expectation(description: "cid scheme task finished with fallback pixel")
        let task = MockURLSchemeTask(
            url: try XCTUnwrap(URL(string: "cid:missing@example.com")),
            didComplete: {
                didFinish.fulfill()
            }
        )
        let stack = testStack!
        let handler = CIDSchemeHandler(
            message: message,
            apiClient: apiClient,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        let beforeFetch = Date()

        handler.webView(WKWebView(), start: task)

        await fulfillment(of: [didFinish], timeout: 2.0)
        XCTAssertNil(task.error)
        XCTAssertEqual(apiClient.getAttachmentCallCount, 1)

        let persistedState = try await fetchAttachmentState(objectID: attachment.objectID)
        XCTAssertEqual(persistedState.state, .failed)
        let failedAt = try XCTUnwrap(persistedState.lastDownloadFailedAt)
        XCTAssertGreaterThanOrEqual(failedAt, beforeFetch)
        XCTAssertGreaterThan(failedAt, staleFailureDate)
    }

    func testStoppedTaskReceivesNoCallbacksAfterDelayedFallbackCompletes() async throws {
        let message = MessageBuilder()
            .withId("message-cid-cancel")
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId("att-cid-cancel")
            .withFilename("cancel.png")
            .withMimeType("image/png")
            .withContentId("cancel@example.com")
            .queued()
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses["\(message.id):\(attachment.id!)"] = imageData
        apiClient.artificialDelay = 0.15
        defer {
            AttachmentPaths.deleteFile(
                at: AttachmentPaths.originalPath(
                    messageId: message.id,
                    attachmentId: "att-cid-cancel",
                    ext: "png"
                )
            )
        }

        let unexpectedCompletion = expectation(description: "stopped cid scheme task should not complete")
        unexpectedCompletion.isInverted = true
        let task = MockURLSchemeTask(
            url: try XCTUnwrap(URL(string: "cid:cancel@example.com")),
            didComplete: {
                unexpectedCompletion.fulfill()
            }
        )
        let stack = testStack!
        let handler = CIDSchemeHandler(
            message: message,
            apiClient: apiClient,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )

        handler.webView(WKWebView(), start: task)
        try await waitUntil(timeout: 1.0) {
            apiClient.getAttachmentCallCount == 1
        }
        handler.webView(WKWebView(), stop: task)

        await fulfillment(of: [unexpectedCompletion], timeout: 0.4)
        XCTAssertEqual(task.callbackCount, 0)
        XCTAssertNil(task.response)
        XCTAssertTrue(task.receivedData.isEmpty)
        XCTAssertNil(task.error)
    }

    func testDuplicateCIDRequestsCoalesceIntoSingleFallbackFetch() async throws {
        let message = MessageBuilder()
            .withId("message-cid-coalesce")
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId("att-cid-coalesce")
            .withFilename("coalesce.png")
            .withMimeType("image/png")
            .withContentId("coalesce@example.com")
            .queued()
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])
        let apiClient = MockGmailAPIClient()
        apiClient.attachmentResponses["\(message.id):\(attachment.id!)"] = imageData
        apiClient.artificialDelay = 0.1
        defer {
            AttachmentPaths.deleteFile(
                at: AttachmentPaths.originalPath(
                    messageId: message.id,
                    attachmentId: "att-cid-coalesce",
                    ext: "png"
                )
            )
        }

        let firstFinished = expectation(description: "first cid scheme task finished")
        let secondFinished = expectation(description: "second cid scheme task finished")
        let cidURL = try XCTUnwrap(URL(string: "cid:coalesce@example.com"))
        let firstTask = MockURLSchemeTask(url: cidURL) {
            firstFinished.fulfill()
        }
        let secondTask = MockURLSchemeTask(url: cidURL) {
            secondFinished.fulfill()
        }
        let stack = testStack!
        let handler = CIDSchemeHandler(
            message: message,
            apiClient: apiClient,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )

        handler.webView(WKWebView(), start: firstTask)
        handler.webView(WKWebView(), start: secondTask)

        await fulfillment(of: [firstFinished, secondFinished], timeout: 2.0)
        XCTAssertEqual(apiClient.getAttachmentCallCount, 1)
        XCTAssertEqual(firstTask.receivedData, imageData)
        XCTAssertEqual(secondTask.receivedData, imageData)
        XCTAssertNil(firstTask.error)
        XCTAssertNil(secondTask.error)
    }

    func testCIDResolutionUsesObjectIDAfterViewContextObjectsAreReleased() async throws {
        AttachmentPaths.setupDirectories()
        var message: Message? = MessageBuilder()
            .withId("message-cid-objectid")
            .withAttachments()
            .build(in: context)
        let attachmentId = "att-cid-objectid"
        let localPath = AttachmentPaths.originalPath(
            messageId: try XCTUnwrap(message).id,
            attachmentId: attachmentId,
            ext: "png"
        )
        let localData = Data([0x89, 0x50, 0x4E, 0x47, 0x11])
        XCTAssertTrue(AttachmentPaths.saveData(localData, to: localPath))
        defer { AttachmentPaths.deleteFile(at: localPath) }

        AttachmentBuilder()
            .withId(attachmentId)
            .withFilename("objectid.png")
            .withMimeType("image/png")
            .withContentId("objectid@example.com")
            .downloaded()
            .withLocalURL(localPath)
            .forMessage(try XCTUnwrap(message))
            .build(in: context)
        try testStack.saveViewContext()

        let stack = testStack!
        let handler = CIDSchemeHandler(
            message: try XCTUnwrap(message),
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        message = nil
        context.reset()

        let didFinish = expectation(description: "cid scheme task finished after view context reset")
        let task = MockURLSchemeTask(
            url: try XCTUnwrap(URL(string: "cid:objectid@example.com")),
            didComplete: {
                didFinish.fulfill()
            }
        )

        handler.webView(WKWebView(), start: task)

        await fulfillment(of: [didFinish], timeout: 2.0)
        XCTAssertNil(task.error)
        XCTAssertEqual(task.receivedData, localData)
        XCTAssertEqual(task.response?.mimeType, "image/png")
    }

    func testLocalAttachmentPathRendersWithoutFallbackFetch() async throws {
        AttachmentPaths.setupDirectories()
        let localPath = AttachmentPaths.originalPath(idOrUUID: "cid-local-\(UUID().uuidString)", ext: "png")
        let localData = Data([0x89, 0x50, 0x4E, 0x47, 0x22])
        XCTAssertTrue(AttachmentPaths.saveData(localData, to: localPath))
        defer { AttachmentPaths.deleteFile(at: localPath) }

        let message = MessageBuilder()
            .withId("message-cid-local")
            .withAttachments()
            .build(in: context)
        AttachmentBuilder()
            .withId("local_cid-attachment")
            .withFilename("local.png")
            .withMimeType("image/png")
            .withContentId("local@example.com")
            .downloaded()
            .withLocalURL(localPath)
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let apiClient = MockGmailAPIClient()
        let didFinish = expectation(description: "local cid scheme task finished")
        let task = MockURLSchemeTask(
            url: try XCTUnwrap(URL(string: "cid:local@example.com")),
            didComplete: {
                didFinish.fulfill()
            }
        )
        let stack = testStack!
        let handler = CIDSchemeHandler(
            message: message,
            apiClient: apiClient,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )

        handler.webView(WKWebView(), start: task)

        await fulfillment(of: [didFinish], timeout: 2.0)
        XCTAssertNil(task.error)
        XCTAssertEqual(task.receivedData, localData)
        XCTAssertEqual(task.response?.mimeType, "image/png")
        XCTAssertEqual(apiClient.getAttachmentCallCount, 0)
    }

    func testLegacySynthesizedInlinePathDoesNotRenderSiblingMessageBytes() async throws {
        AttachmentPaths.setupDirectories()
        let attachmentID = "local_inline_reused-metadata-hash"
        let legacyPath = AttachmentPaths.originalPath(idOrUUID: attachmentID, ext: "png")
        let staleData = Data([0x89, 0x50, 0x4E, 0x47, 0x33])
        XCTAssertTrue(AttachmentPaths.saveData(staleData, to: legacyPath))
        defer { AttachmentPaths.deleteFile(at: legacyPath) }

        let message = MessageBuilder()
            .withId("message-cid-legacy-inline")
            .withAttachments()
            .build(in: context)
        AttachmentBuilder()
            .withId(attachmentID)
            .withFilename("inline.png")
            .withMimeType("image/png")
            .withContentId("legacy-inline@example.com")
            .downloaded()
            .withLocalURL(legacyPath)
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let apiClient = MockGmailAPIClient()
        let didFinish = expectation(description: "legacy inline cid uses safe fallback")
        let task = MockURLSchemeTask(
            url: try XCTUnwrap(URL(string: "cid:legacy-inline@example.com")),
            didComplete: { didFinish.fulfill() }
        )
        let stack = testStack!
        let handler = CIDSchemeHandler(
            message: message,
            apiClient: apiClient,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )

        handler.webView(WKWebView(), start: task)

        await fulfillment(of: [didFinish], timeout: 2.0)
        XCTAssertNil(task.error)
        XCTAssertEqual(task.response?.mimeType, "image/gif")
        XCTAssertNotEqual(task.receivedData, staleData)
        XCTAssertEqual(apiClient.getMessageCallCount, 1)
        XCTAssertEqual(apiClient.getAttachmentCallCount, 0)
    }

    func testLegacySynthesizedInlineCIDRecoversOnlyAuthoritativeMessageBytes() async throws {
        AttachmentPaths.setupDirectories()
        // The Attachments directory is process-global and outlives the run on
        // the simulator, so both file paths are UUID-isolated: the synthesized
        // attachment ID hashes the Content-ID (legacy ID-only path) and the
        // message ID keys the recovered message-scoped path.
        let runID = UUID().uuidString.lowercased()
        let messageID = "message-cid-legacy-inline-recovery-\(runID)"
        let contentID = "legacy-recovery-\(runID)@example.com"
        let authoritativeData = Data([0x89, 0x50, 0x4E, 0x47, 0x45, 0x53, 0x43])
        let recoveredMessage = makeSynthesizedInlineMessage(
            messageID: messageID,
            data: authoritativeData,
            partID: "2.1",
            filename: "inline.png",
            mimeType: "image/png",
            contentID: contentID
        )
        let legacyPath = AttachmentPaths.originalPath(
            idOrUUID: recoveredMessage.attachmentID,
            ext: "png"
        )
        let recoveredPath = AttachmentPaths.originalPath(
            messageId: messageID,
            attachmentId: recoveredMessage.attachmentID,
            ext: "png"
        )
        let recoveredPreviewPath = AttachmentPaths.previewPath(
            messageId: messageID,
            attachmentId: recoveredMessage.attachmentID
        )
        // Registered before the handler starts: if the wait below ever times
        // out, these are still the only paths recovery can write.
        defer {
            AttachmentPaths.deleteFile(at: legacyPath)
            AttachmentPaths.deleteFile(at: recoveredPath)
            AttachmentPaths.deleteFile(at: recoveredPreviewPath)
        }
        let staleSiblingData = Data("stale sibling bytes".utf8)
        XCTAssertTrue(AttachmentPaths.saveData(staleSiblingData, to: legacyPath))

        let message = MessageBuilder()
            .withId(messageID)
            .withAttachments()
            .build(in: context)
        let attachment = AttachmentBuilder()
            .withId(recoveredMessage.attachmentID)
            .withFilename("inline.png")
            .withMimeType("image/png")
            .withContentId(contentID)
            .downloaded()
            .withLocalURL(legacyPath)
            .forMessage(message)
            .build(in: context)
        try testStack.saveViewContext()

        let apiClient = MockGmailAPIClient()
        apiClient.getMessageResponses[messageID] = recoveredMessage.message
        let task = MockURLSchemeTask(
            url: try XCTUnwrap(URL(string: "cid:\(contentID)")),
            didComplete: {}
        )
        let stack = testStack!
        let handler = CIDSchemeHandler(
            message: message,
            apiClient: apiClient,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )

        handler.webView(WKWebView(), start: task)

        // Wall-clock deadline, not a latency budget. Recovery is the longest
        // chain in this suite (MainActor task → background-context lookup →
        // coalescer actor → getMessage → .utility detached file write and image
        // decode → Core Data save → MainActor response), and the old 2s
        // expectation lost it on main's CI run for PR #230, where the whole
        // test process stalled for 1–3s at a time (synchronous neighbours such
        // as CacheCoordinatorInvalidationPlanTests.testUpdatedAttachment_isNotCollected
        // took 2.98s instead of ~0.1s). Green runs exit on the first poll after
        // didFinish; bailing on timeout keeps one clear failure instead of four
        // assertions reading a half-finished recovery.
        guard try await waitUntil(timeout: 15.0, { task.isFinished }) else { return }
        let persistedPath: String? = try await testStack.performBackgroundTask { context in
            (try? context.existingObject(with: attachment.objectID) as? Attachment)?.localURL
        }

        XCTAssertEqual(persistedPath, recoveredPath)
        XCTAssertNil(task.error)
        XCTAssertEqual(task.response?.mimeType, "image/png")
        XCTAssertEqual(task.receivedData, authoritativeData)
        XCTAssertNotEqual(task.receivedData, staleSiblingData)
        XCTAssertEqual(apiClient.getMessageCallCount, 1)
        XCTAssertEqual(apiClient.getAttachmentCallCount, 0)
        XCTAssertTrue(
            AttachmentPaths.isReadableStoragePath(
                persistedPath,
                messageId: messageID,
                attachmentId: recoveredMessage.attachmentID
            )
        )
        XCTAssertEqual(AttachmentPaths.loadData(from: persistedPath), authoritativeData)
    }

    @discardableResult
    private func waitUntil(
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return false
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private func fetchAttachmentState(
        objectID: NSManagedObjectID
    ) async throws -> (state: Attachment.State, lastDownloadFailedAt: Date?) {
        try await testStack.performBackgroundTask { context in
            guard let attachment = try context.existingObject(with: objectID) as? Attachment else {
                throw NSError(domain: "CIDSchemeHandlerTests", code: 1)
            }
            return (attachment.state, attachment.lastDownloadFailedAt)
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

private final class MockURLSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest

    private let lock = NSLock()
    private let didComplete: () -> Void
    private var storedResponse: URLResponse?
    private var storedData = Data()
    private var storedError: Error?
    private var finished = false
    private var didReceiveResponseCount = 0
    private var didReceiveDataCount = 0
    private var didFinishCount = 0
    private var didFailCount = 0

    init(url: URL, didComplete: @escaping () -> Void) {
        self.request = URLRequest(url: url)
        self.didComplete = didComplete
        super.init()
    }

    var response: URLResponse? {
        lock.lock()
        defer { lock.unlock() }
        return storedResponse
    }

    var receivedData: Data {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    var callbackCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return didReceiveResponseCount + didReceiveDataCount + didFinishCount + didFailCount
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func didReceive(_ response: URLResponse) {
        lock.lock()
        storedResponse = response
        didReceiveResponseCount += 1
        lock.unlock()
    }

    func didReceive(_ data: Data) {
        lock.lock()
        storedData.append(data)
        didReceiveDataCount += 1
        lock.unlock()
    }

    func didFinish() {
        lock.lock()
        didFinishCount += 1
        lock.unlock()
        complete(error: nil)
    }

    func didFailWithError(_ error: Error) {
        lock.lock()
        didFailCount += 1
        lock.unlock()
        complete(error: error)
    }

    private func complete(error: Error?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        storedError = error
        lock.unlock()
        didComplete()
    }
}
