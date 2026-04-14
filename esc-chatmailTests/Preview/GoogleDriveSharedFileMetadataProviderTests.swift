import XCTest
@testable import esc_chatmail

final class GoogleDriveSharedFileMetadataProviderTests: XCTestCase {
    override func tearDown() {
        TestURLProtocol.reset()
        super.tearDown()
    }

    func testParseMetadata_prefersOpenGraphTitleAndImage() {
        let link = SharedDocumentLink(
            id: "SharedDocumentLink.Kind.googleDoc|doc123",
            url: URL(string: "https://docs.google.com/document/d/doc123/edit?usp=sharing")!,
            kind: .googleDoc
        )
        let html = """
        <html>
        <head>
        <meta property="og:title" content="Omakase Update 260407 - Google Docs">
        <meta property="og:image" content="https://lh7-rt.googleusercontent.com/docsz/preview123">
        <title>Ignored Title</title>
        </head>
        </html>
        """

        let metadata = GoogleDriveSharedFileMetadataProvider.parseMetadata(from: html, link: link)

        XCTAssertEqual(metadata?.title, "Omakase Update 260407")
        XCTAssertEqual(
            metadata?.thumbnailURL,
            "https://lh7-rt.googleusercontent.com/docsz/preview123"
        )
    }

    func testParseMetadata_fallsBackToTitleTagAndThumbnailEndpoint() {
        let link = SharedDocumentLink(
            id: "SharedDocumentLink.Kind.googleSlides|slides123",
            url: URL(string: "https://docs.google.com/presentation/d/slides123/edit")!,
            kind: .googleSlides
        )
        let html = """
        <html>
        <head>
        <title>Chop Chop Update 260408 - Google Slides</title>
        </head>
        </html>
        """

        let metadata = GoogleDriveSharedFileMetadataProvider.parseMetadata(from: html, link: link)

        XCTAssertEqual(metadata?.title, "Chop Chop Update 260408")
        XCTAssertEqual(
            metadata?.thumbnailURL,
            "https://drive.google.com/thumbnail?id=slides123&sz=w1600"
        )
    }

    func testParseMetadata_returnsNilForSignInTitle() {
        let link = SharedDocumentLink(
            id: "SharedDocumentLink.Kind.googleSheet|sheet123",
            url: URL(string: "https://docs.google.com/spreadsheets/d/sheet123/edit")!,
            kind: .googleSheet
        )
        let html = """
        <html>
        <head>
        <title>Sign in - Google Accounts</title>
        </head>
        </html>
        """

        let metadata = GoogleDriveSharedFileMetadataProvider.parseMetadata(from: html, link: link)

        XCTAssertNil(metadata)
    }

    func testParseMetadata_preservesApostrophesInDoubleQuotedMetaContent() {
        let link = SharedDocumentLink(
            id: "SharedDocumentLink.Kind.googleDoc|doc456",
            url: URL(string: "https://docs.google.com/document/d/doc456/edit")!,
            kind: .googleDoc
        )
        let html = """
        <html>
        <head>
        <meta property="og:title" content="Today's plan - Google Docs">
        </head>
        </html>
        """

        let metadata = GoogleDriveSharedFileMetadataProvider.parseMetadata(from: html, link: link)

        XCTAssertEqual(metadata?.title, "Today's plan")
    }

    func testParseMetadata_preservesDoubleQuotesInSingleQuotedMetaContent() {
        let link = SharedDocumentLink(
            id: "SharedDocumentLink.Kind.googleDoc|doc789",
            url: URL(string: "https://docs.google.com/document/d/doc789/edit")!,
            kind: .googleDoc
        )
        let html = """
        <html>
        <head>
        <meta content='The "Launch" Plan - Google Docs' property='og:title'>
        </head>
        </html>
        """

        let metadata = GoogleDriveSharedFileMetadataProvider.parseMetadata(from: html, link: link)

        XCTAssertEqual(metadata?.title, "The \"Launch\" Plan")
    }

    func testMetadata_retriesAfterBlockedPageResponse() async {
        let link = SharedDocumentLink(
            id: "SharedDocumentLink.Kind.googleDoc|doc123",
            url: URL(string: "https://docs.google.com/document/d/doc123/edit?usp=sharing")!,
            kind: .googleDoc
        )
        let provider = GoogleDriveSharedFileMetadataProvider(session: makeTestSession())

        TestURLProtocol.responders = [
            { request in
                try Self.makeHTMLResponse(
                    for: request,
                    html: """
                    <html>
                    <head>
                    <title>Sign in - Google Accounts</title>
                    </head>
                    </html>
                    """
                )
            },
            { request in
                try Self.makeHTMLResponse(
                    for: request,
                    html: """
                    <html>
                    <head>
                    <meta property="og:title" content="Launch Plan - Google Docs">
                    </head>
                    </html>
                    """
                )
            }
        ]

        let firstResult = await provider.metadata(for: link)
        let secondResult = await provider.metadata(for: link)

        XCTAssertEqual(firstResult, GoogleDriveSharedFileMetadataProvider.fallbackMetadata(for: link))
        XCTAssertEqual(secondResult.title, "Launch Plan")
        XCTAssertEqual(TestURLProtocol.requestedURLs, [link.url, link.url])
    }

    func testMetadata_fetchesNewURLVariantAfterInitialFailureForSameResource() async {
        let failedLink = SharedDocumentLink(
            id: "SharedDocumentLink.Kind.googleDoc|doc123",
            url: URL(string: "https://docs.google.com/document/d/doc123/edit?usp=sharing")!,
            kind: .googleDoc
        )
        let recoveredLink = SharedDocumentLink(
            id: failedLink.id,
            url: URL(string: "https://docs.google.com/document/d/doc123/edit?usp=sharing&resourcekey=abc")!,
            kind: .googleDoc
        )
        let provider = GoogleDriveSharedFileMetadataProvider(session: makeTestSession())

        TestURLProtocol.responders = [
            { request in
                try Self.makeResponse(for: request, statusCode: 404, body: "")
            },
            { request in
                try Self.makeHTMLResponse(
                    for: request,
                    html: """
                    <html>
                    <head>
                    <meta property="og:title" content="Recovered Title - Google Docs">
                    </head>
                    </html>
                    """
                )
            }
        ]

        let firstResult = await provider.metadata(for: failedLink)
        let secondResult = await provider.metadata(for: recoveredLink)

        XCTAssertEqual(
            firstResult,
            GoogleDriveSharedFileMetadataProvider.fallbackMetadata(for: failedLink)
        )
        XCTAssertEqual(secondResult.title, "Recovered Title")
        XCTAssertEqual(TestURLProtocol.requestedURLs, [failedLink.url, recoveredLink.url])
    }

    private func makeTestSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func makeHTMLResponse(
        for request: URLRequest,
        html: String
    ) throws -> (HTTPURLResponse, Data) {
        try makeResponse(
            for: request,
            statusCode: 200,
            body: html
        )
    }

    private static func makeResponse(
        for request: URLRequest,
        statusCode: Int,
        body: String
    ) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
              ) else {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)
        }

        return (response, Data(body.utf8))
    }
}

private final class TestURLProtocol: URLProtocol {
    typealias Responder = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    static var responders: [Responder] = []
    static var requestedURLs: [URL] = []

    static func reset() {
        lock.lock()
        responders = []
        requestedURLs = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let responder: Responder?
        let requestURL = request.url

        Self.lock.lock()
        if let requestURL {
            Self.requestedURLs.append(requestURL)
        }
        responder = Self.responders.isEmpty ? nil : Self.responders.removeFirst()
        Self.lock.unlock()

        guard let responder else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse))
            return
        }

        do {
            let (response, data) = try responder(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
