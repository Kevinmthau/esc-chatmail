import XCTest
@testable import esc_chatmail

final class EmailPreviewSourceLoaderTests: XCTestCase {
    func testLoadPreviewSourceExtractsTextImagesAndClassification() async throws {
        let messageId = "preview-source-newsletter-\(UUID().uuidString)"
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        let html = """
        <!DOCTYPE html>
        <html>
        <body>
          <p>View in browser</p>
          <h1>Tickets are now on sale for the Spring Documentary Festival</h1>
          <img src="https://cdn.example.com/hero.jpg" width="640" height="320" alt="Hero artwork">
          <p>Join us for outstanding documentary films and immersive conversations around the world.</p>
          <p><a href="https://example.com/unsubscribe">Unsubscribe</a></p>
          <p><a href="https://example.com/preferences">Manage Preferences</a></p>
        </body>
        </html>
        """
        HTMLContentHandler.shared.saveHTML(html, for: messageId)

        let loader = EmailPreviewSourceLoader(htmlContentLoader: HTMLContentLoader())
        let source = await loader.loadPreviewSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Fallback preview text",
            senderEmail: "newsletter@example.com",
            subject: "Spring Documentary Festival",
            allowRecovery: false
        )

        let unwrappedSource = try XCTUnwrap(source)
        XCTAssertEqual(unwrappedSource.messageId, messageId)
        XCTAssertTrue(unwrappedSource.sourceSignature.hasPrefix("sha256:"))
        XCTAssertEqual(unwrappedSource.plainText, "Fallback preview text")
        XCTAssertTrue(unwrappedSource.extractedText?.contains("Spring Documentary Festival") == true)
        XCTAssertEqual(unwrappedSource.classification.kind, .newsletter)
        XCTAssertEqual(unwrappedSource.extractedImages.first?.sourceURL, "https://cdn.example.com/hero.jpg")
        XCTAssertEqual(unwrappedSource.extractedImages.first?.width, 640)
        XCTAssertEqual(unwrappedSource.extractedImages.first?.height, 320)

        let preview = NewsletterPreviewBuilder().buildPreview(
            source: unwrappedSource,
            cleanedSnippet: nil,
            senderName: "Example Newsletter",
            senderEmail: "newsletter@example.com",
            subject: "Spring Documentary Festival"
        )

        XCTAssertEqual(preview?.heroImageURL, "https://cdn.example.com/hero.jpg")
        XCTAssertEqual(preview?.heroImageDisplayMode, .fill)
    }

    func testLoadPreviewSourceUsesCanonicalHTMLSignatureForChangedMessageBody() async throws {
        let messageId = "preview-source-refresh-\(UUID().uuidString)"
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        let loader = EmailPreviewSourceLoader(htmlContentLoader: HTMLContentLoader())
        HTMLContentHandler.shared.saveHTML(
            """
            <html><body><h1>First newsletter update</h1><p>View in browser</p><p>Unsubscribe</p></body></html>
            """,
            for: messageId
        )

        let loadedFirst = await loader.loadPreviewSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: "newsletter@example.com",
            subject: "Newsletter update",
            allowRecovery: false
        )
        let first = try XCTUnwrap(loadedFirst)

        HTMLContentHandler.shared.saveHTML(
            """
            <html><body><h1>Second newsletter update</h1><p>View in browser</p><p>Unsubscribe</p></body></html>
            """,
            for: messageId
        )

        let loadedSecond = await loader.loadPreviewSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: "newsletter@example.com",
            subject: "Newsletter update",
            allowRecovery: false
        )
        let second = try XCTUnwrap(loadedSecond)

        XCTAssertNotEqual(first.sourceSignature, second.sourceSignature)
        XCTAssertTrue(second.extractedText?.contains("Second newsletter update") == true)
        XCTAssertFalse(second.extractedText?.contains("First newsletter update") == true)
    }

    func testTransactionalBuilderUsesPreviewSourceImageCandidates() async throws {
        let messageId = "preview-source-transactional-\(UUID().uuidString)"
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        HTMLContentHandler.shared.saveHTML(
            """
            <!DOCTYPE html>
            <html>
            <body>
              <h1>Your ride with Alex</h1>
              <p>Total paid: $42.19</p>
              <img src="https://images.example.com/profile.jpg" width="96" height="96" alt="Driver profile image">
              <p>Payment complete</p>
            </body>
            </html>
            """,
            for: messageId
        )

        let loadedSource = await EmailPreviewSourceLoader(htmlContentLoader: HTMLContentLoader()).loadPreviewSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: "receipts@example.com",
            subject: "Your ride receipt",
            allowRecovery: false
        )
        let source = try XCTUnwrap(loadedSource)

        let preview = TransactionalPreviewBuilder().buildPreview(
            source: source,
            cleanedSnippet: nil,
            senderName: "Ride Receipts",
            senderEmail: "receipts@example.com",
            subject: "Your ride receipt"
        )

        XCTAssertEqual(preview?.amount, "$42.19")
        XCTAssertEqual(preview?.imageURL, "https://images.example.com/profile.jpg")
        XCTAssertEqual(preview?.imageStyle, .avatar)
    }
}
