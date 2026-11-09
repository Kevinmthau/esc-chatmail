import XCTest
@testable import esc_chatmail

/// End-to-end guards: the SSRF private-IP filter must prevent any outbound
/// request for URLs from untrusted email content that target private /
/// loopback / link-local / reserved addresses.
final class SSRFGuardIntegrationTests: XCTestCase {

    // MARK: - HTMLRemoteImageAttachmentFallback

    func testRemoteImageFallback_neverFetchesPrivateIPs() async {
        let recorder = RequestCounter()
        let service = HTMLRemoteImageAttachmentFallback { _ in
            await recorder.record()
            XCTFail("Executor invoked for a private-IP URL — SSRF guard failed")
            return (Data(), URLResponse())
        }

        let htmlCases = [
            "<html><body><img src=\"http://169.254.169.254/latest/meta-data/\"></body></html>",
            "<html><body><img src=\"http://192.168.1.1/admin\"></body></html>",
            "<html><body><img src=\"http://127.0.0.1:6379/\"></body></html>",
            "<html><body><img src=\"http://10.0.0.5/secret\"></body></html>",
            "<html><body><img src=\"http://[::1]/probe\"></body></html>",
            "<html><body><img src=\"http://2130706433/\"></body></html>",
            "<html><body><img src=\"http://localhost:8080/\"></body></html>",
            "<html><body><img src=\"http://router.local/\"></body></html>"
        ]

        for html in htmlCases {
            let result = await service.inlineAttachmentStyleImages(
                in: html,
                senderEmail: "attacker@example.com"
            )
            // The HTML should pass through unchanged (no inlining happened).
            XCTAssertEqual(result, html, "HTML was modified for blocked URL: \(html)")
        }

        let count = await recorder.count
        XCTAssertEqual(count, 0, "Expected no executor invocations, got \(count)")
    }

    func testRemoteImageFallback_fetchesPublicIPsWhenEligible() async {
        let recorder = RequestCounter()
        let service = HTMLRemoteImageAttachmentFallback { _ in
            await recorder.record()
            // Minimal response — just prove we got past the guard.
            let response = HTTPURLResponse(
                url: URL(string: "https://example.com/")!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: [:]
            )!
            return (Data(), response)
        }

        // Use an eligible URL shape (dynamic extension) so the candidate
        // passes `isEligibleCandidate` if the guard doesn't block it.
        let html = "<html><body><img src=\"https://cdn.example.com/asset.php\"></body></html>"
        _ = await service.inlineAttachmentStyleImages(in: html, senderEmail: "sender@example.com")

        let count = await recorder.count
        XCTAssertGreaterThan(count, 0, "Expected executor to be invoked for a public URL")
    }

    // MARK: - GoogleDriveSharedFileMetadataProvider

    func testDriveMetadataProvider_rejectsPrivateIPHost() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailOnUseURLProtocol.self]
        FailOnUseURLProtocol.reset()
        let session = URLSession(configuration: config)

        let provider = GoogleDriveSharedFileMetadataProvider(session: session)
        let link = SharedDocumentLink(
            id: "SharedDocumentLink.Kind.googleDoc|internal",
            url: URL(string: "http://192.168.1.1/document/d/abc/edit")!,
            kind: .googleDoc
        )

        let result = await provider.metadata(for: link)

        XCTAssertEqual(result, GoogleDriveSharedFileMetadataProvider.fallbackMetadata(for: link))
        XCTAssertEqual(FailOnUseURLProtocol.startCount, 0, "Session should not have been used for private-IP URL")
    }

    func testDriveMetadataProvider_rejectsNonAllowedHost() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailOnUseURLProtocol.self]
        FailOnUseURLProtocol.reset()
        let session = URLSession(configuration: config)

        let provider = GoogleDriveSharedFileMetadataProvider(session: session)
        let link = SharedDocumentLink(
            id: "SharedDocumentLink.Kind.googleDoc|spoofed",
            url: URL(string: "https://docs.google.com.attacker.example/document/d/abc/edit")!,
            kind: .googleDoc
        )

        let result = await provider.metadata(for: link)

        XCTAssertEqual(result, GoogleDriveSharedFileMetadataProvider.fallbackMetadata(for: link))
        XCTAssertEqual(FailOnUseURLProtocol.startCount, 0, "Session should not have been used for non-allowed host")
    }

    // MARK: - RemoteImageFetcher

    func testRemoteImageFetcher_rejectsPrivateIPBeforeNetwork() async {
        await assertFetcherRejectsBeforeNetwork(["http://169.254.169.254/latest/meta-data/"])
    }

    /// The no-click path: a remote image whose host is a private address written with a trailing
    /// dot must be refused before any request leaves.
    ///
    /// Revert-check: classifying `url.host` as given in
    /// `PrivateNetworkAddressDetector.classifiableHost(of:)`, without dropping the trailing dot,
    /// makes this fail: the fetcher starts a request.
    ///
    /// HONEST SCOPE: the guard was the only thing in front of an https request, not an http one.
    /// Measured on the iOS 27.0 simulator against a loopback listener: `getaddrinfo` resolves the
    /// dotted address and `https://127.0.0.1.:<port>/` opened a connection, but App Transport
    /// Security refused `http://127.0.0.1.:<port>/` (`NSURLErrorDomain` -1022, no connection),
    /// which is the spelling these URLs use.
    func testRemoteImageFetcher_rejectsTrailingDotPrivateIPBeforeNetwork() async {
        await assertFetcherRejectsBeforeNetwork([
            "http://169.254.169.254./latest/meta-data/",
            "http://192.168.1.1./cgi-bin/reboot"
        ])
    }

    /// The no-click path for a private address written with a leading-zero part. Unlike the
    /// trailing-dot spelling, this one was reachable over plain http: measured on the iOS 27.0
    /// simulator, a `URLSession` GET of `http://0127.0.0.1:<port>/` returned 200 from a loopback
    /// listener. App Transport Security did not refuse it, and the resolver read the host as
    /// decimal 127.0.0.1 while the detector read it as octal 87.0.0.1.
    ///
    /// Revert-check: returning only the `inet_aton` reading from
    /// `PrivateNetworkAddressDetector.ipv4Readings(of:)`, without the dotted-decimal one, makes
    /// this fail: the fetcher starts a request.
    func testRemoteImageFetcher_rejectsLeadingZeroPrivateIPBeforeNetwork() async {
        await assertFetcherRejectsBeforeNetwork([
            "http://0127.0.0.1/",
            "http://010.0.0.1/cgi-bin/reboot",
            "http://169.0254.169.254/latest/meta-data/"
        ])
    }

    /// Runs each URL through a `RemoteImageFetcher` whose session records any use, and expects
    /// `.privateOrReservedHost` for every one with no request started.
    private func assertFetcherRejectsBeforeNetwork(
        _ urlStrings: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailOnUseURLProtocol.self]
        FailOnUseURLProtocol.reset()
        let fetcher = RemoteImageFetcher(session: URLSession(configuration: config))

        for urlString in urlStrings {
            do {
                _ = try await fetcher.imageData(from: urlString)
                XCTFail("Expected \(urlString) to be rejected", file: file, line: line)
            } catch RemoteImageFetchError.privateOrReservedHost {
                // Expected.
            } catch {
                XCTFail("Unexpected error for \(urlString): \(error)", file: file, line: line)
            }
        }

        XCTAssertEqual(
            FailOnUseURLProtocol.startCount,
            0,
            "Session should not have been used for \(urlStrings)",
            file: file,
            line: line
        )
    }

    func testRemoteImageFetcher_rejectsNonImageContentType() async {
        RemoteImageURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteImageURLProtocol.self]
        let session = URLSession(configuration: config)
        let fetcher = RemoteImageFetcher(session: session)
        let url = URL(string: "https://cdn.openai.com/avatar")!

        RemoteImageURLProtocol.responder = { request in
            let response = HTTPURLResponse(
                url: request.url ?? url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("<html></html>".utf8))
        }

        do {
            _ = try await fetcher.imageData(from: url.absoluteString)
            XCTFail("Expected non-image response to be rejected")
        } catch RemoteImageFetchError.unsupportedContentType(let contentType) {
            XCTAssertEqual(contentType, "text/html")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(RemoteImageURLProtocol.requestCount, 1)
    }
}

// MARK: - Helpers

private actor RequestCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private final class FailOnUseURLProtocol: URLProtocol {
    nonisolated(unsafe) static var startCount = 0
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        startCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.startCount += 1
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override func stopLoading() {}
}

private final class RemoteImageURLProtocol: URLProtocol {
    typealias Responder = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) static var responder: Responder?
    nonisolated(unsafe) static var requestCount = 0

    static func reset() {
        lock.lock()
        responder = nil
        requestCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let currentResponder: Responder?
        Self.lock.lock()
        Self.requestCount += 1
        currentResponder = Self.responder
        Self.lock.unlock()

        guard let currentResponder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try currentResponder(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
