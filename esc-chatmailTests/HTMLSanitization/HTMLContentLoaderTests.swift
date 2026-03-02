import XCTest
@testable import esc_chatmail

final class HTMLContentLoaderTests: XCTestCase {
    private var contentHandler: HTMLContentHandler!
    private var loader: HTMLContentLoader!

    override func setUp() {
        super.setUp()
        contentHandler = HTMLContentHandler()
        loader = HTMLContentLoader(contentHandler: contentHandler, sanitizer: .shared)
    }

    override func tearDown() {
        contentHandler = nil
        loader = nil
        super.tearDown()
    }

    func testLoadContent_cleanupModeQuotedOnlyRemovesGmailQuoteBlocks() async {
        let messageId = "html-loader-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let html = """
        <div>MAIN_BODY_TOKEN</div>
        <div class="gmail_quote">QUOTED_BODY_TOKEN</div>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let unstripped = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            cleanupMode: .none
        )

        let stripped = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            cleanupMode: .quotedOnly
        )

        XCTAssertNotNil(unstripped.html)
        XCTAssertNotNil(stripped.html)
        XCTAssertTrue(unstripped.html?.contains("QUOTED_BODY_TOKEN") == true)
        XCTAssertFalse(stripped.html?.contains("QUOTED_BODY_TOKEN") == true)
        XCTAssertTrue(stripped.html?.contains("MAIN_BODY_TOKEN") == true)
    }

    func testLoadContent_cacheSeparatesCleanupModeVariants() async {
        let messageId = "html-loader-cache-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let html = """
        <p>BODY_A</p>
        <blockquote>BODY_QUOTE</blockquote>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let first = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            cleanupMode: .none
        )
        let second = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            cleanupMode: .quotedOnly
        )

        XCTAssertTrue(first.html?.contains("BODY_QUOTE") == true)
        XCTAssertFalse(second.html?.contains("BODY_QUOTE") == true)
    }

    func testLoadContent_cleanupModeQuotedOnlyPreservesSignatureBlock() async {
        let messageId = "html-loader-signature-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let html = """
        <p>Hello there</p>
        <div class="signature">SIGNATURE_TOKEN</div>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let quotedOnly = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            cleanupMode: .quotedOnly
        )

        let quotedAndSignature = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            cleanupMode: .quotedAndSignature
        )

        XCTAssertTrue(quotedOnly.html?.contains("SIGNATURE_TOKEN") == true)
        XCTAssertFalse(quotedAndSignature.html?.contains("SIGNATURE_TOKEN") == true)
    }

    func testLoadContent_cleanupModeQuotedAndSignatureDoesNotReturnBlankForTransactionalTemplate() async {
        // Minimized, anonymized transactional-template style email. Some templates can trigger
        // overly aggressive signature cleanup heuristics; we should never return a blank HTML
        // document to the WebView as a result.
        let messageId = "html-loader-transactional-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let transactionalHTML = """
        <!DOCTYPE html>
        <html>
          <head>
            <title>Statement Ready</title>
            <style>
              body { margin: 0; padding: 0; background: #ffffff; }
              table { border-collapse: collapse; }
            </style>
          </head>
          <body>
            <table width="100%"><tr><td><img src="https://example.com/logo.png" alt="logo" width="140"></td></tr></table>
            <table><tr><td><strong>Your credit facility statement is ready</strong></td></tr></table>
            <table><tr><td>To review your statement, please log on to example.com or the Mobile app.</td></tr></table>
            <table><tr><td><a href="https://example.com/review">Review Statement</a></td></tr></table>
            <div>
              This is a service message with information related to your account. It may include details about
              transactions, products, or online services. Please do not reply directly to this message.
              Your privacy is important to us. See our Privacy Policy and Security Center to learn how to protect
              your information.
            </div>
          </body>
        </html>
        """
        _ = contentHandler.saveHTML(transactionalHTML, for: messageId)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            cleanupMode: .quotedAndSignature
        )

        XCTAssertNotNil(result.html)
        XCTAssertTrue((result.html ?? "").contains("Your credit facility statement is ready"))
    }

    func testLoadContent_plainTextFallbackAutoLinksGoogleSheetsURLs() async {
        let messageId = "html-loader-plain-link-\(UUID().uuidString)"
        let bodyText = """
        Here are the spreadsheets:
        https://docs.google.com/spreadsheets/d/1abcDEF234xyz/edit?usp=sharing&gid=42
        """

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: bodyText,
            isDarkMode: false,
            cleanupMode: .none
        )

        guard case .plainTextFallback = result.source else {
            XCTFail("Expected plainTextFallback source")
            return
        }

        let html = result.html ?? ""
        XCTAssertTrue(html.contains("href=\"https://docs.google.com/spreadsheets/d/1abcDEF234xyz/edit?usp=sharing&amp;gid=42\""))
        XCTAssertTrue(html.contains(">https://docs.google.com/spreadsheets/d/1abcDEF234xyz/edit?usp=sharing&amp;gid=42</a>"))
    }

    func testLoadContent_plainTextFallbackDoesNotAutoLinkUnsupportedSchemes() async {
        let messageId = "html-loader-plain-unsupported-\(UUID().uuidString)"
        let bodyText = "Internal file server: ftp://files.example.com/shared/report.csv"

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: bodyText,
            isDarkMode: false,
            cleanupMode: .none
        )

        guard case .plainTextFallback = result.source else {
            XCTFail("Expected plainTextFallback source")
            return
        }

        let html = result.html ?? ""
        XCTAssertTrue(html.contains("ftp://files.example.com/shared/report.csv"))
        XCTAssertFalse(html.contains("href=\"ftp://files.example.com/shared/report.csv\""))
    }
}
