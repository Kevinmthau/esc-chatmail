import XCTest
@testable import esc_chatmail

final class MessageBubbleContentSourceTests: XCTestCase {

    func testContentSourceSignature_usesOnlyHTMLMetadataForStoredHTML() {
        let handler = HTMLContentHandler.shared
        let messageId = "test-source-signature-\(UUID().uuidString)"
        defer {
            handler.deleteHTML(for: messageId)
        }

        let html = "<html><body><p>\(String(repeating: "Large message body. ", count: 1000))</p></body></html>"
        XCTAssertNotNil(handler.saveHTML(html, for: messageId))

        let htmlSignature = handler.htmlSourceSignature(messageId: messageId, bodyStorageURI: nil)
        let sourceSignature = MessageBubbleContentSource.contentSourceSignature(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            handler: handler
        )
        XCTAssertEqual(sourceSignature, "html:\(htmlSignature)")
        XCTAssertFalse(sourceSignature.hasPrefix("html:sha256:"))

        let sourceSignatureWithBody = MessageBubbleContentSource.contentSourceSignature(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Fallback body",
            handler: handler
        )
        XCTAssertEqual(sourceSignatureWithBody, "html:\(htmlSignature)")
    }

    func testFallbackContentSourceSignature_includesBodyTextForStoredHTML() {
        let handler = HTMLContentHandler.shared
        let messageId = "test-fallback-source-signature-\(UUID().uuidString)"
        defer {
            handler.deleteHTML(for: messageId)
        }

        XCTAssertNotNil(handler.saveHTML("<html><body><img src=\"cid:image\"></body></html>", for: messageId))

        let htmlSignature = handler.htmlSourceSignature(messageId: messageId, bodyStorageURI: nil)
        let sourceSignature = MessageBubbleContentSource.fallbackContentSourceSignature(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Fallback body",
            handler: handler
        )

        XCTAssertTrue(sourceSignature.hasPrefix("html:\(htmlSignature)|fallback-body:sha256:"))
    }

    func testContentSourceSignature_usesBodyTextWhenHTMLMissing() {
        let handler = HTMLContentHandler.shared
        let messageId = "test-missing-html-source-signature-\(UUID().uuidString)"
        handler.deleteHTML(for: messageId)

        let sourceSignature = MessageBubbleContentSource.contentSourceSignature(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Fallback body",
            handler: handler
        )
        XCTAssertTrue(sourceSignature.hasPrefix("body:sha256:"))
    }
}
