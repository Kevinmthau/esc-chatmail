import XCTest
@testable import esc_chatmail

/// `SSRFGuardingURLSession.boundedData`: the read of a sender's URL that stops at a size
/// limit while the body arrives (architecture review 2026-11, `security-privacy#1` and
/// `networking#6`). The session is made as the shared one is, redirect guard included, with
/// its requests answered by `StreamingStubURLProtocol`.
final class SSRFBoundedDataTests: XCTestCase {
    private var session: URLSession!
    private var urls: [URL] = []

    override func setUp() {
        super.setUp()
        session = SSRFGuardingURLSession.makeSession(protocolClasses: [StreamingStubURLProtocol.self])
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        StreamingStubURLProtocol.removeScripts(for: urls)
        urls = []
        super.tearDown()
    }

    // MARK: - The body

    func testBoundedData_bodyWithinTheLimitArrivingInChunks_isReturnedWhole() async throws {
        let chunks = (0..<5).map { Data(repeating: UInt8($0 + 1), count: 300) }
        let url = scripted(.init(headers: ["Content-Type": "image/png"], chunks: chunks))

        let (data, response) = try await SSRFGuardingURLSession.boundedData(
            for: URLRequest(url: url),
            maxBytes: 4_096,
            session: session
        )

        XCTAssertEqual(data, chunks.reduce(Data(), +))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    /// The limit is the most the caller takes, so a body of exactly that many bytes is taken.
    func testBoundedData_bodyOfExactlyTheLimit_isReturned() async throws {
        let body = Data(repeating: 7, count: 1_024)
        let url = scripted(.init(chunks: [body]))

        let (data, _) = try await SSRFGuardingURLSession.boundedData(
            for: URLRequest(url: url),
            maxBytes: 1_024,
            session: session
        )

        XCTAssertEqual(data, body)
    }

    /// A body that declares no length is given up as soon as it has run past the limit.
    ///
    /// Revert-check: the `guard body.count < maxBytes` in `boundedData`'s read loop. Without
    /// it the whole body is returned.
    func testBoundedData_undeclaredBodyRunningPastTheLimit_throwsAndStopsTheTransfer() async throws {
        let chunks = Array(repeating: Data(repeating: 1, count: 1_024), count: 64)
        let url = scripted(.init(chunks: chunks))

        do {
            let (data, _) = try await SSRFGuardingURLSession.boundedData(
                for: URLRequest(url: url),
                maxBytes: 4_096,
                session: session
            )
            XCTFail("A body of \(data.count) bytes was returned past a limit of 4,096")
        } catch let tooLarge as SSRFGuardingURLSession.ResponseTooLarge {
            XCTAssertEqual(tooLarge, .init(declaredByteCount: nil, maxBytes: 4_096))
        }
        await waitUntil { StreamingStubURLProtocol.didStopLoading(url) }
    }

    func testBoundedData_bodyOneByteOverTheLimit_throws() async throws {
        let url = scripted(.init(chunks: [Data(repeating: 7, count: 1_025)]))

        do {
            _ = try await SSRFGuardingURLSession.boundedData(
                for: URLRequest(url: url),
                maxBytes: 1_024,
                session: session
            )
            XCTFail("Expected the body to be refused")
        } catch let tooLarge as SSRFGuardingURLSession.ResponseTooLarge {
            XCTAssertEqual(tooLarge.maxBytes, 1_024)
        }
    }

    // MARK: - Decided on the headers

    /// A declared length past the limit is refused on the headers. The stub sends the first
    /// bytes of the body and never ends its load, so only a reader that did not wait for
    /// the rest returns.
    ///
    /// Revert-check: the `declaredByteCount > Int64(maxBytes)` check in `boundedData`.
    /// Without it the read waits for the rest of the body until the session's request
    /// timeout, and what is thrown is that timeout.
    func testBoundedData_declaredLengthPastTheLimit_throwsOnTheHeadersAndStopsTheTransfer() async throws {
        let url = scripted(.init(
            headers: ["Content-Length": "9000000"],
            chunks: [Data(repeating: 1, count: StreamingStubURLProtocol.sniffedByteCount)],
            finishes: false
        ))

        do {
            _ = try await SSRFGuardingURLSession.boundedData(
                for: URLRequest(url: url),
                maxBytes: 8 * 1_024 * 1_024,
                session: session
            )
            XCTFail("Expected the response to be refused on its declared length")
        } catch let tooLarge as SSRFGuardingURLSession.ResponseTooLarge {
            XCTAssertEqual(tooLarge, .init(declaredByteCount: 9_000_000, maxBytes: 8 * 1_024 * 1_024))
        }
        await waitUntil { StreamingStubURLProtocol.didStopLoading(url) }
    }

    /// What the caller refuses on the headers is thrown as the caller threw it, and the
    /// transfer is stopped: the stub never ends its load by itself.
    ///
    /// HONEST SCOPE: the wait below pins that the transfer stops, not what stops it. With
    /// `bytes.task.cancel()` taken out of `boundedData`'s catch it still stops (letting go
    /// of the bytes ends their task), so no test here fails on that revert.
    func testBoundedData_responseTheCallerRefuses_throwsTheCallersErrorAndStopsTheTransfer() async throws {
        struct Refused: Error {}
        let url = scripted(.init(
            statusCode: 404,
            chunks: [Data(repeating: 1, count: StreamingStubURLProtocol.sniffedByteCount)],
            finishes: false
        ))

        do {
            _ = try await SSRFGuardingURLSession.boundedData(
                for: URLRequest(url: url),
                maxBytes: 4_096,
                session: session,
                acceptResponse: { response in
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Refused() }
                }
            )
            XCTFail("Expected the caller's refusal to be thrown")
        } catch is Refused {
            // Expected.
        }
        await waitUntil { StreamingStubURLProtocol.didStopLoading(url) }
    }

    // MARK: - The session's redirect guard

    /// The redirect guard is the session's delegate, and this read's task is made by
    /// `bytes(for:)`: the guard has to be asked about that task's redirects too, or a public
    /// host could answer a sender's image URL with a redirect to an address inside the
    /// user's network.
    ///
    /// Revert-check: `completionHandler(nil)` for a private address in
    /// `SSRFGuardingURLSession.RedirectGuard`. Following the redirect starts a load of the
    /// private URL.
    func testBoundedData_redirectToAPrivateAddress_isNotFollowed() async throws {
        let privateURL = StreamingStubURLProtocol.uniqueURL(host: "169.254.169.254", path: "latest/meta-data")
        urls.append(privateURL)
        StreamingStubURLProtocol.setScript(.init(chunks: [Data("secret".utf8)]), for: privateURL)
        let url = scripted(.init(redirect: privateURL))

        let result = try? await SSRFGuardingURLSession.boundedData(
            for: URLRequest(url: url),
            maxBytes: 4_096,
            session: session
        )

        XCTAssertFalse(StreamingStubURLProtocol.didStartLoading(privateURL))
        XCTAssertNotEqual(result?.0, Data("secret".utf8))
    }

    /// The other half, so that the test above cannot pass because this stub's redirects
    /// are never followed by anything.
    func testBoundedData_redirectToAPublicAddress_isFollowed() async throws {
        let destination = scripted(.init(chunks: [Data("picture".utf8)]))
        let url = scripted(.init(redirect: destination))

        let (data, _) = try await SSRFGuardingURLSession.boundedData(
            for: URLRequest(url: url),
            maxBytes: 4_096,
            session: session
        )

        XCTAssertTrue(StreamingStubURLProtocol.didStartLoading(destination))
        XCTAssertEqual(data, Data("picture".utf8))
    }

    // MARK: - Who reads through it

    /// The two fetchers of a sender's image read through `boundedData`. `data(for:)` in
    /// either one is a body buffered whole before any limit is applied to it.
    func testSenderImageFetchers_doNotBufferAWholeBodyWithDataFor() throws {
        for path in [
            "esc-chatmail/Services/Caching/RemoteImageFetcher.swift",
            "esc-chatmail/Services/HTMLSanitization/HTMLRemoteImageAttachmentFallback.swift"
        ] {
            let source = try repositorySource(path)
            XCTAssertTrue(source.contains("SSRFGuardingURLSession.boundedData("), path)
            XCTAssertFalse(source.contains(".data(for:"), path)
        }
    }

    // MARK: - Helpers

    private func scripted(_ script: StreamingStubURLProtocol.Script) -> URL {
        let url = StreamingStubURLProtocol.uniqueURL()
        urls.append(url)
        StreamingStubURLProtocol.setScript(script, for: url)
        return url
    }

    /// Polls `condition` until it holds or `timeout` elapses. The condition is checked
    /// before the deadline on every pass, so a stall longer than the timeout cannot fail a
    /// condition that came true during the stall.
    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
