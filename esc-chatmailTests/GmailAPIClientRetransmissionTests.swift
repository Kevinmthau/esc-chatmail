import XCTest
@testable import esc_chatmail

/// Verifies that non-idempotent requests (messages.send) are never retransmitted
/// after ambiguous failures, while idempotent requests keep full retry behavior.
final class GmailAPIClientRetransmissionTests: XCTestCase {

    private var tokenManager: MockTokenManager!
    private var client: GmailAPIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        tokenManager = MockTokenManager()
        client = GmailAPIClient(
            tokenManager: tokenManager,
            retryStrategy: NetworkRetryStrategy(maxRetries: 3, initialDelay: 0.01, maxDelay: 0.02),
            session: session
        )
    }

    override func tearDown() {
        StubURLProtocol.reset()
        client = nil
        tokenManager = nil
        super.tearDown()
    }

    private static let sendResponseBody = Data(#"{"id":"sent-1","threadId":"thread-1"}"#.utf8)
    private static let messageResponseBody = Data(#"{"id":"m1","threadId":"t1"}"#.utf8)

    // MARK: - Send is not retransmitted on ambiguous failures

    func testSendMessage_serverError_isNotRetransmitted() async {
        StubURLProtocol.script = [.status(500)]

        do {
            _ = try await client.sendMessage(rawMessage: "raw")
            XCTFail("Expected serverError")
        } catch let APIError.serverError(code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1, "A 5xx is ambiguous for send; it must not be retransmitted")
    }

    func testSendMessage_timeout_isNotRetransmitted() async {
        StubURLProtocol.script = [.error(URLError(.timedOut))]

        do {
            _ = try await client.sendMessage(rawMessage: "raw")
            XCTFail("Expected timeout error")
        } catch {
            // expected
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1, "A timeout is ambiguous for send; it must not be retransmitted")
    }

    func testSendMessage_connectionLost_isNotRetransmitted() async {
        StubURLProtocol.script = [.error(URLError(.networkConnectionLost))]

        do {
            _ = try await client.sendMessage(rawMessage: "raw")
            XCTFail("Expected connection error")
        } catch {
            // expected
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1, "A dropped connection is ambiguous for send; it must not be retransmitted")
    }

    // MARK: - Send is still retried when the request provably never went through

    func testSendMessage_cannotConnect_isRetried() async throws {
        StubURLProtocol.script = [
            .error(URLError(.cannotConnectToHost)),
            .data(200, Self.sendResponseBody)
        ]

        let response = try await client.sendMessage(rawMessage: "raw")

        XCTAssertEqual(response.id, "sent-1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "Connect failures prove the request was never delivered; retry is safe")
    }

    func testSendMessage_tlsHandshakeFailure_isRetried() async throws {
        StubURLProtocol.script = [
            .error(URLError(.secureConnectionFailed)),
            .data(200, Self.sendResponseBody)
        ]

        let response = try await client.sendMessage(rawMessage: "raw")

        XCTAssertEqual(response.id, "sent-1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "A TLS handshake failure proves no application data was sent; retry is safe")
    }

    func testSendMessage_rateLimited_isRetried() async throws {
        StubURLProtocol.script = [
            .status(429),
            .data(200, Self.sendResponseBody)
        ]

        let response = try await client.sendMessage(rawMessage: "raw")

        XCTAssertEqual(response.id, "sent-1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "A 429 proves the request was rejected; retry is safe")
    }

    func testSendMessage_unauthorized_refreshesTokenAndRetries() async throws {
        StubURLProtocol.script = [
            .status(401),
            .data(200, Self.sendResponseBody)
        ]

        let response = try await client.sendMessage(rawMessage: "raw")

        XCTAssertEqual(response.id, "sent-1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "A 401 proves the request was rejected; refresh + retry is safe")
        XCTAssertEqual(tokenManager.refreshTokenCallCount, 1)
    }

    // MARK: - Idempotent requests keep full retry behavior

    func testGetMessage_serverError_isRetried() async throws {
        StubURLProtocol.script = [
            .status(500),
            .data(200, Self.messageResponseBody)
        ]

        let message = try await client.getMessage(id: "m1")

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "Idempotent requests must keep retrying 5xx responses")
    }

    func testGetMessage_timeout_isRetried() async throws {
        StubURLProtocol.script = [
            .error(URLError(.timedOut)),
            .data(200, Self.messageResponseBody)
        ]

        let message = try await client.getMessage(id: "m1")

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "Idempotent requests must keep retrying timeouts")
    }
}

// MARK: - Stub URL Protocol

/// Serves a scripted sequence of responses; the last entry repeats once the
/// script is exhausted. State is static (URLProtocol instances are created by
/// the URL loading system) and lock-guarded.
private final class StubURLProtocol: URLProtocol {
    enum Response {
        case status(Int)
        case data(Int, Data)
        case error(URLError)
    }

    private static let lock = NSLock()
    private static var _script: [Response] = []
    private static var _requestCount = 0

    static var script: [Response] {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }

    static var requestCount: Int {
        lock.withLock { _requestCount }
    }

    static func reset() {
        lock.withLock {
            _script = []
            _requestCount = 0
        }
    }

    private static func nextResponse() -> Response? {
        lock.withLock {
            _requestCount += 1
            guard !_script.isEmpty else { return nil }
            return _script.count > 1 ? _script.removeFirst() : _script[0]
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let response = Self.nextResponse() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        switch response {
        case .status(let code):
            send(url: url, statusCode: code, body: Data())
        case .data(let code, let body):
            send(url: url, statusCode: code, body: body)
        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func send(url: URL, statusCode: Int, body: Data) {
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
