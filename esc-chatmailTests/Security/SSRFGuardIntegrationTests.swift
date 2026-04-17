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
