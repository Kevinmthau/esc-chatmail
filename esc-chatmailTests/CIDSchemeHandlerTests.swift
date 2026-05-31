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
        defer { AttachmentPaths.deleteFile(at: AttachmentPaths.originalPath(idOrUUID: "att-cid-cancel", ext: "png")) }

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
        defer { AttachmentPaths.deleteFile(at: AttachmentPaths.originalPath(idOrUUID: "att-cid-coalesce", ext: "png")) }

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
        let localPath = AttachmentPaths.originalPath(idOrUUID: "cid-objectid-\(UUID().uuidString)", ext: "png")
        let localData = Data([0x89, 0x50, 0x4E, 0x47, 0x11])
        XCTAssertTrue(AttachmentPaths.saveData(localData, to: localPath))
        defer { AttachmentPaths.deleteFile(at: localPath) }

        var message: Message? = MessageBuilder()
            .withId("message-cid-objectid")
            .withAttachments()
            .build(in: context)
        AttachmentBuilder()
            .withId("att-cid-objectid")
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
            .withId("att-cid-local")
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

    private func waitUntil(
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
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
