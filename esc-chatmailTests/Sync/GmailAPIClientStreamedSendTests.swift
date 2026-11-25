import XCTest
@testable import esc_chatmail

private actor StreamedSendBarrierProbe {
    private(set) var callCount = 0

    func record() {
        callCount += 1
    }
}

/// What one attempt looked like as it started: the body the loading system handed
/// the protocol (an upload's `httpBodyStream`, drained) and the upload files on disk.
private struct StreamedSendAttempt {
    let contentType: String?
    let streamedBody: Data?
    let uploadFiles: [Data]
}

/// Collects `StreamedSendAttempt`s from `StubURLProtocol.onStartLoading`, which runs on
/// the loading system's thread. `@unchecked Sendable`: `lock` guards `attempts`.
private final class StreamedSendAttemptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _attempts: [StreamedSendAttempt] = []
    private let uploadDirectory: URL

    init(uploadDirectory: URL) {
        self.uploadDirectory = uploadDirectory
    }

    var attempts: [StreamedSendAttempt] {
        lock.withLock { _attempts }
    }

    func record(_ request: URLRequest) {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: uploadDirectory,
            includingPropertiesForKeys: nil
        )) ?? []).compactMap { try? Data(contentsOf: $0) }
        let attempt = StreamedSendAttempt(
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            streamedBody: request.httpBodyStream.map(Self.drain),
            uploadFiles: files
        )
        lock.withLock { _attempts.append(attempt) }
    }

    private static func drain(_ stream: InputStream) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        stream.open()
        defer { stream.close() }
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// The real `GmailAPIClient` through `StubURLProtocol`: messages.send goes to the
/// upload endpoint as a multipart body streamed from a file, the file lives exactly
/// as long as the send, and the send's outcome rules are those of the in-memory body
/// it replaced. `GmailAPIClientRetransmissionTests` runs every outcome case through
/// the same upload path.
final class GmailAPIClientStreamedSendTests: XCTestCase {
    private var tokenManager: MockTokenManager!
    private var uploadDirectory: URL!
    private var client: GmailAPIClient!

    private static let sendResponseBody = Data(#"{"id":"sent-1","threadId":"thread-1"}"#.utf8)
    private static let mime = Data("From: me@example.com\r\nSubject: photos\r\n\r\nbody\r\n".utf8)

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        tokenManager = MockTokenManager()
        uploadDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GmailAPIClientStreamedSendTests-\(UUID().uuidString)", isDirectory: true)
        client = makeClient(uploadDirectory: uploadDirectory)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: uploadDirectory)
        client = nil
        uploadDirectory = nil
        tokenManager = nil
        super.tearDown()
    }

    private func makeClient(uploadDirectory: URL) -> GmailAPIClient {
        GmailAPIClient(
            tokenManager: tokenManager,
            retryStrategy: NetworkRetryStrategy(maxRetries: 3, initialDelay: 0.01, maxDelay: 0.02),
            session: StubURLProtocol.makeSession(),
            retryClock: FakeSyncClock(),
            sendUploadDirectory: uploadDirectory
        )
    }

    private func expectedBody(boundary: String, threadId: String?) -> Data {
        let metadata = threadId.map { #"{"threadId":"\#($0)"}"# } ?? "{}"
        return Data(
            ("--\(boundary)\r\n"
                + "Content-Type: application/json; charset=UTF-8\r\n\r\n"
                + metadata
                + "\r\n--\(boundary)\r\n"
                + "Content-Type: message/rfc822\r\n\r\n").utf8
        ) + Self.mime + Data("\r\n--\(boundary)--\r\n".utf8)
    }

    private func boundary(of contentType: String?) throws -> String {
        let prefix = "multipart/related; boundary="
        let value = try XCTUnwrap(contentType)
        XCTAssertTrue(value.hasPrefix(prefix), value)
        return String(value.dropFirst(prefix.count))
    }

    private func uploadFilesLeft() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: uploadDirectory.path)) ?? []
    }

    // MARK: - The request

    /// Revert-check: `APIEndpoints.sendMessageUpload()` and the `uploadType`
    /// query item in `GmailAPIClient.sendMessage(mimeData:…)`: the send then goes to
    /// the JSON endpoint, which reads the body as `{"raw": …}`.
    func testSendMessage_postsAMultipartUploadToTheUploadEndpoint() async throws {
        StubURLProtocol.script = [.data(200, Self.sendResponseBody)]

        let response = try await client.sendMessage(mimeData: Self.mime, threadId: "thread-1")

        XCTAssertEqual(response.id, "sent-1")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "gmail.googleapis.com")
        XCTAssertEqual(url.path, "/upload/gmail/v1/users/me/messages/send")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query, [URLQueryItem(name: "uploadType", value: "multipart")])
        XCTAssertEqual(request.httpMethod, "POST")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/related; boundary="), contentType)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - The file lives exactly as long as the send

    /// Revert-check: the `defer { upload.remove() }` in `sendMessage(mimeData:…)`.
    func testSendMessage_success_removesItsUploadFile() async throws {
        StubURLProtocol.script = [.data(200, Self.sendResponseBody)]

        _ = try await client.sendMessage(mimeData: Self.mime)

        XCTAssertEqual(uploadFilesLeft(), [])
    }

    /// A dropped connection after the barrier is still ambiguous, never retried,
    /// and leaves no file behind.
    func testSendMessage_connectionLostDuringTheUpload_isAmbiguousNotResentAndRemovesItsFile() async {
        StubURLProtocol.script = [.error(URLError(.networkConnectionLost))]

        do {
            _ = try await client.sendMessage(mimeData: Self.mime)
            XCTFail("Expected ambiguous delivery")
        } catch GmailMessageSendError.ambiguousDelivery(let underlying) {
            XCTAssertEqual((underlying as? URLError)?.code, .networkConnectionLost)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1, "A dropped upload is ambiguous; it must not be resent")
        XCTAssertEqual(uploadFilesLeft(), [])
    }

    /// What goes out is the file, and the file is the multipart body.
    ///
    /// Revert-check: the `if let bodyFile` branch in
    /// `GmailAPIClient.performRetryingRequest`, or `uploadingBodyFrom:` in
    /// `sendMessage(mimeData:…)`: the send then goes out as a data task with no
    /// body, and the protocol is handed no body stream.
    /// HONEST SCOPE: that the loading system hands a custom protocol an upload's
    /// file as `httpBodyStream` is URLSession's behavior, read here and not
    /// documented; the file assertions hold whether or not it does.
    func testSendMessage_uploadsTheMultipartBodyFromItsFile() async throws {
        let recorder = StreamedSendAttemptRecorder(uploadDirectory: uploadDirectory)
        StubURLProtocol.onStartLoading = { recorder.record($0) }
        StubURLProtocol.script = [.data(200, Self.sendResponseBody)]

        _ = try await client.sendMessage(mimeData: Self.mime, threadId: "thread-1")

        let attempt = try XCTUnwrap(recorder.attempts.first)
        let sentBoundary = try boundary(of: attempt.contentType)
        let expected = expectedBody(boundary: sentBoundary, threadId: "thread-1")
        XCTAssertEqual(attempt.uploadFiles, [expected], "One file, the multipart body, while the upload runs")
        XCTAssertEqual(attempt.streamedBody, expected, "The request's body is the file")
    }

    /// The retry after a 401 uploads the same file again, so the file must still be
    /// there for it. Revert-check: removing the file after each attempt (or the
    /// `defer` moving above the retry loop) leaves the second attempt no file.
    func testSendMessage_unauthorizedThenSuccess_uploadsTheSameFileTwiceThenRemovesIt() async throws {
        let recorder = StreamedSendAttemptRecorder(uploadDirectory: uploadDirectory)
        StubURLProtocol.onStartLoading = { recorder.record($0) }
        StubURLProtocol.script = [.status(401), .data(200, Self.sendResponseBody)]

        let response = try await client.sendMessage(mimeData: Self.mime)

        XCTAssertEqual(response.id, "sent-1")
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        let attempts = recorder.attempts
        XCTAssertEqual(attempts.count, 2)
        let sentBoundary = try boundary(of: attempts.first?.contentType)
        let expected = expectedBody(boundary: sentBoundary, threadId: nil)
        for attempt in attempts {
            XCTAssertEqual(attempt.uploadFiles, [expected], "Every attempt finds the one body file")
            XCTAssertEqual(attempt.streamedBody, expected, "Every attempt sends it")
        }
        XCTAssertEqual(uploadFilesLeft(), [])
    }

    // MARK: - Before the barrier

    /// A failure at the barrier itself (cancellation, a sign-out's teardown) proves
    /// nothing was sent, and the file it wrote goes with it.
    func testSendMessage_barrierRefuses_isNotStartedAndRemovesItsFile() async {
        struct BarrierRefusal: Error {}

        do {
            _ = try await client.sendMessage(
                mimeData: Self.mime,
                threadId: nil,
                beforeTransmission: { throw BarrierRefusal() }
            )
            XCTFail("Expected the barrier's refusal")
        } catch GmailMessageSendError.transmissionNotStarted(let underlying) {
            XCTAssertTrue(underlying is BarrierRefusal, "\(underlying)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 0)
        XCTAssertEqual(uploadFilesLeft(), [])
    }

    /// Revert-check: writing the body file after `beforeTransmission`: a full disk
    /// would then fail after the barrier, as an ambiguous "Delivery unknown" for a
    /// message that never left the device.
    func testSendMessage_uploadFileCannotBeWritten_failsBeforeTheBarrier() async throws {
        try FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
        let blocker = uploadDirectory.appendingPathComponent("blocker")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        client = makeClient(uploadDirectory: blocker.appendingPathComponent("uploads", isDirectory: true))
        let barrier = StreamedSendBarrierProbe()

        do {
            _ = try await client.sendMessage(
                mimeData: Self.mime,
                threadId: nil,
                beforeTransmission: { await barrier.record() }
            )
            XCTFail("Expected a pre-transmission failure")
        } catch GmailMessageSendError.transmissionNotStarted {
            // Expected: definite "Not sent".
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let barrierCalls = await barrier.callCount
        XCTAssertEqual(barrierCalls, 0)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }
}
