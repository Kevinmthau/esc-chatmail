import XCTest
@testable import esc_chatmail

final class OriginalEmailSourceLoaderTests: XCTestCase {
    private var contentHandler: HTMLContentHandler!
    private var recoveryService: MutableRecoveryService!
    private var loader: OriginalEmailSourceLoader!

    override func setUp() {
        super.setUp()
        contentHandler = HTMLContentHandler()
        recoveryService = MutableRecoveryService(contentHandler: contentHandler)
        loader = OriginalEmailSourceLoader(
            canonicalContentLoader: CanonicalEmailContentLoader(
                contentHandler: contentHandler,
                recoveryService: recoveryService
            ),
            htmlContentLoader: HTMLContentLoader(contentHandler: contentHandler, sanitizer: .shared)
        )
    }

    override func tearDown() {
        loader = nil
        recoveryService = nil
        contentHandler = nil
        super.tearDown()
    }

    func testLoadOriginalEmailSource_returnsStoredHTMLForPlainFirstMultipartFixture() async throws {
        let messageId = "original-plain-first-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let plainURLDump = """
        https://tracking.example.com/a
        https://tracking.example.com/b
        Reserve your table
        """
        let html = newsletterHTML(title: "Reserve your table")
        _ = contentHandler.saveHTML(html, for: messageId)

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: plainURLDump,
            senderEmail: "reservations@example.com",
            subject: "Reserve your table",
            isDarkMode: false,
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.presentation, .html)
        XCTAssertEqual(source.sourceKind, .html)
        XCTAssertNil(source.plainText)
        XCTAssertTrue(source.html?.contains("Reserve your table") == true)
        XCTAssertFalse(source.html?.contains("https://tracking.example.com/a") == true)
    }

    func testLoadOriginalEmailSource_returnsStoredHTMLForHTMLFirstMultipartFixture() async throws {
        let messageId = "original-html-first-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let plainURLDump = """
        https://tracking.example.com/a
        https://tracking.example.com/b
        View offer
        """
        let html = newsletterHTML(title: "View offer")
        _ = contentHandler.saveHTML(html, for: messageId)

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: plainURLDump,
            senderEmail: "reservations@example.com",
            subject: "View offer",
            isDarkMode: false,
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.presentation, .html)
        XCTAssertEqual(source.sourceKind, .html)
        XCTAssertNil(source.plainText)
        XCTAssertTrue(source.html?.contains("View offer") == true)
        XCTAssertFalse(source.html?.contains("https://tracking.example.com/a") == true)
    }

    func testLoadOriginalEmailSource_fullNewsletterModelContainsOriginalHTMLMarkers() async throws {
        let messageId = "original-markers-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(newsletterHTML(title: "Book a suite"), for: messageId)

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "https://tracking.example.com/a\nBook a suite",
            senderEmail: "reservations@example.com",
            subject: "Book a suite",
            isDarkMode: false,
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)
        let html = try XCTUnwrap(source.html)

        XCTAssertTrue(html.contains("<!DOCTYPE"))
        XCTAssertTrue(html.lowercased().contains("<html"))
        XCTAssertTrue(html.lowercased().contains("<table"))
        XCTAssertTrue(html.lowercased().contains("<img"))
        XCTAssertTrue(html.contains("href=\"https://example.com/cta\""))
    }

    func testLoadOriginalEmailSource_plainTextOnlyRendersNativePlainText() async throws {
        let messageId = "original-plain-only-\(UUID().uuidString)"

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Plain text only\nhttps://example.com",
            senderEmail: "person@example.com",
            subject: "Plain",
            isDarkMode: false,
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.presentation, .nativePlainText)
        XCTAssertEqual(source.sourceKind, .plainText)
        XCTAssertEqual(source.plainText, "Plain text only\nhttps://example.com")
        XCTAssertNil(source.html)
    }

    func testLoadOriginalEmailSource_unusableStoredHTMLFallsBackToNativePlainText() async throws {
        let messageId = "original-unusable-html-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(
            """
            <html><body><div style="display: none;">Tracking shell</div></body></html>
            """,
            for: messageId
        )

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Visible plain text fallback",
            senderEmail: "person@example.com",
            subject: "Fallback",
            isDarkMode: false,
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.presentation, .nativePlainText)
        XCTAssertEqual(source.sourceKind, .plainText)
        XCTAssertTrue(source.hasHTMLSource)
        XCTAssertEqual(source.plainText, "Visible plain text fallback")
        XCTAssertNil(source.html)
    }

    func testLoadOriginalEmailSource_unusableStoredHTMLRetriesRecoveryBeforePlainTextFallback() async throws {
        let messageId = "original-unusable-html-recovery-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(
            """
            <html><body><div style="display: none;">Tracking shell</div></body></html>
            """,
            for: messageId
        )
        recoveryService.setHTML(newsletterHTML(title: "Recovered original"), for: messageId)

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "https://tracking.example.com/open\nRecovered original",
            senderEmail: "newsletter@example.com",
            subject: "Recovered",
            isDarkMode: false,
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.presentation, .html)
        XCTAssertEqual(source.sourceKind, .recoveredHTML)
        XCTAssertNil(source.plainText)
        XCTAssertTrue(source.html?.contains("Recovered original") == true)
        XCTAssertFalse(source.html?.contains("https://tracking.example.com/open") == true)
    }

    func testLoadOriginalEmailSource_unusableMessageFileContinuesToStorageURIHTML() async throws {
        let messageId = "original-storage-fallback-\(UUID().uuidString)"
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(messageId)-storage.html")
        defer {
            contentHandler.deleteHTML(for: messageId)
            try? FileManager.default.removeItem(at: storageURL)
        }

        _ = contentHandler.saveHTML(
            """
            <html><body><div style="display: none;">Tracking shell</div></body></html>
            """,
            for: messageId
        )
        try newsletterHTML(title: "Storage original").write(to: storageURL, atomically: true, encoding: .utf8)

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: storageURL.path,
            bodyText: "https://tracking.example.com/open\nStorage original",
            senderEmail: "newsletter@example.com",
            subject: "Storage",
            isDarkMode: false,
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.presentation, .html)
        XCTAssertEqual(source.sourceLocation, .storageURI)
        XCTAssertNil(source.plainText)
        XCTAssertTrue(source.html?.contains("Storage original") == true)
        XCTAssertFalse(source.html?.contains("https://tracking.example.com/open") == true)
    }

    func testLoadOriginalEmailSource_rawSourceFallbackDoesNotPointToStaleMessageFile() async throws {
        let messageId = "original-raw-fallback-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(
            """
            <html><body><div style="display: none;">Tracking shell</div></body></html>
            """,
            for: messageId
        )

        let loadedSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: rawMultipartAlternativeSource(
                plainText: "https://tracking.example.com/open\nRaw original",
                html: newsletterHTML(title: "Raw original")
            ),
            senderEmail: "newsletter@example.com",
            subject: "Raw",
            isDarkMode: false,
            timeout: 5.0
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.presentation, .html)
        XCTAssertEqual(source.sourceLocation, .rawSourceHTML)
        XCTAssertFalse(source.shouldPointBodyStorageURIAtMessageFile)
        XCTAssertTrue(source.html?.contains("Raw original") == true)
    }

    func testLoadOriginalEmailSource_recoveryUpgradesPlainTextWithoutStaleCache() async throws {
        let messageId = "original-recovery-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let firstSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Plain fallback before recovery",
            senderEmail: "newsletter@example.com",
            subject: "Recovered",
            isDarkMode: false,
            timeout: 5.0
        )
        let first = try XCTUnwrap(firstSource)
        XCTAssertEqual(first.presentation, .nativePlainText)

        recoveryService.setHTML(newsletterHTML(title: "Recovered HTML"), for: messageId)

        let recoveredSource = await loader.loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Plain fallback before recovery",
            senderEmail: "newsletter@example.com",
            subject: "Recovered",
            isDarkMode: false,
            timeout: 5.0
        )
        let recovered = try XCTUnwrap(recoveredSource)

        XCTAssertEqual(recovered.presentation, .html)
        XCTAssertEqual(recovered.sourceKind, .recoveredHTML)
        XCTAssertTrue(recovered.html?.contains("Recovered HTML") == true)
        XCTAssertTrue(contentHandler.loadHTML(for: messageId)?.contains("Recovered HTML") == true)
    }

    private func newsletterHTML(title: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <body>
          <table role="presentation">
            <tr>
              <td>
                <img src="https://cdn.example.com/hero.jpg" alt="Hero">
                <h1>\(title)</h1>
                <a href="https://example.com/cta">Reserve now</a>
              </td>
            </tr>
          </table>
        </body>
        </html>
        """
    }

    private func rawMultipartAlternativeSource(plainText: String, html: String) -> String {
        """
        From: newsletter@example.com
        To: person@example.com
        Subject: Raw
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="raw-boundary"

        --raw-boundary
        Content-Type: text/plain; charset="UTF-8"

        \(plainText)

        --raw-boundary
        Content-Type: text/html; charset="UTF-8"

        \(html)

        --raw-boundary--
        """
    }
}

private final class MutableRecoveryService: HTMLContentRecovering, @unchecked Sendable {
    private let lock = NSLock()
    private let contentHandler: HTMLContentHandler
    private var htmlByMessageID: [String: String] = [:]

    init(contentHandler: HTMLContentHandler) {
        self.contentHandler = contentHandler
    }

    func setHTML(_ html: String, for messageId: String) {
        lock.lock()
        htmlByMessageID[messageId] = html
        lock.unlock()
    }

    func recoverHTMLContent(messageId: String) async -> String? {
        lock.lock()
        let html = htmlByMessageID[messageId]
        lock.unlock()

        if let html {
            _ = contentHandler.saveHTML(html, for: messageId)
        }

        return html
    }
}
