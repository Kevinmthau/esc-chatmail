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

    func testLoadContent_stripQuotedContentRemovesGmailQuoteBlocks() async {
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
            stripQuotedContent: false
        )

        let stripped = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            stripQuotedContent: true
        )

        XCTAssertNotNil(unstripped.html)
        XCTAssertNotNil(stripped.html)
        XCTAssertTrue(unstripped.html?.contains("QUOTED_BODY_TOKEN") == true)
        XCTAssertFalse(stripped.html?.contains("QUOTED_BODY_TOKEN") == true)
        XCTAssertTrue(stripped.html?.contains("MAIN_BODY_TOKEN") == true)
    }

    func testLoadContent_cacheSeparatesStripQuotedContentVariants() async {
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
            stripQuotedContent: false
        )
        let second = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            stripQuotedContent: true
        )

        XCTAssertTrue(first.html?.contains("BODY_QUOTE") == true)
        XCTAssertFalse(second.html?.contains("BODY_QUOTE") == true)
    }
}
