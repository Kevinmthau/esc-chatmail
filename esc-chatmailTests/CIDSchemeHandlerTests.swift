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
}

private final class MockURLSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest

    private let lock = NSLock()
    private let didComplete: () -> Void
    private var storedResponse: URLResponse?
    private var storedData = Data()
    private var storedError: Error?
    private var finished = false

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

    func didReceive(_ response: URLResponse) {
        lock.lock()
        storedResponse = response
        lock.unlock()
    }

    func didReceive(_ data: Data) {
        lock.lock()
        storedData.append(data)
        lock.unlock()
    }

    func didFinish() {
        complete(error: nil)
    }

    func didFailWithError(_ error: Error) {
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
