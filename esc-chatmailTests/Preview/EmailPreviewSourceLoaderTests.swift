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
        XCTAssertEqual(
            unwrappedSource.htmlSummary.h1Text,
            "Tickets are now on sale for the Spring Documentary Festival"
        )
        XCTAssertTrue(unwrappedSource.htmlSummary.actionLinkTexts.contains("Manage Preferences"))

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

    func testLoadPreviewSourceExtractsComplexNewsletterSummary() async throws {
        let messageId = "preview-source-complex-newsletter-\(UUID().uuidString)"
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        HTMLContentHandler.shared.saveHTML(
            """
            <!DOCTYPE html>
            <html>
            <head>
              <title>Documentary Festival Dispatch</title>
            </head>
            <body>
              <span class="preheader" style="display:none;max-height:0">
                Festival passes are now available for opening weekend
              </span>
              <table role="presentation">
                <tr>
                  <td>
                    <h1><a href="https://example.com/festival">Spring Documentary Festival opens tonight</a></h1>
                    <img src="https://cdn.example.com/festival-hero.jpg" width="720" height="360" alt="Festival hero">
                    <p>Join filmmakers and audiences for premieres, panels, and late-night screenings.</p>
                    <p><a href="https://example.com/lineup"><span>Read the lineup</span></a></p>
                  </td>
                </tr>
              </table>
              <p>Manage Preferences</p>
              <p>Unsubscribe</p>
            </body>
            </html>
            """,
            for: messageId
        )

        let loadedSource = await EmailPreviewSourceLoader(htmlContentLoader: HTMLContentLoader()).loadPreviewSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: "newsletter@example.com",
            subject: "Festival dispatch",
            allowRecovery: false
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.htmlSummary.preheaderText, "Festival passes are now available for opening weekend")
        XCTAssertEqual(source.htmlSummary.h1Text, "Spring Documentary Festival opens tonight")
        XCTAssertEqual(source.htmlSummary.titleText, "Documentary Festival Dispatch")
        XCTAssertTrue(source.htmlSummary.actionLinkTexts.contains("Read the lineup"))
        XCTAssertEqual(source.extractedImages.first?.sourceURL, "https://cdn.example.com/festival-hero.jpg")
    }

    func testLoadPreviewSourceCapsSummaryActionLinkTextsAfterEmptyAnchors() async throws {
        let messageId = "preview-source-action-link-cap-\(UUID().uuidString)"
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        let emptyLinks = (1...3)
            .map { "<a href=\"https://example.com/empty-\($0)\"></a>" }
            .joined(separator: "\n")
        let actionLinks = (1...20)
            .map { "<a href=\"https://example.com/action-\($0)\">Action \($0)</a>" }
            .joined(separator: "\n")

        HTMLContentHandler.shared.saveHTML(
            """
            <!DOCTYPE html>
            <html>
            <body>
              <h1>Daily deals</h1>
              \(emptyLinks)
              \(actionLinks)
            </body>
            </html>
            """,
            for: messageId
        )

        let loadedSource = await EmailPreviewSourceLoader(htmlContentLoader: HTMLContentLoader()).loadPreviewSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: "newsletter@example.com",
            subject: "Daily deals",
            allowRecovery: false
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertEqual(source.htmlSummary.actionLinkTexts.count, 12)
        XCTAssertEqual(source.htmlSummary.actionLinkTexts.first, "Action 1")
        XCTAssertEqual(source.htmlSummary.actionLinkTexts.last, "Action 12")
        XCTAssertFalse(source.htmlSummary.actionLinkTexts.contains("Action 13"))
    }

    func testLoadPreviewSourceCapsSummaryActionLinkAnchorScan() async throws {
        let messageId = "preview-source-anchor-scan-cap-\(UUID().uuidString)"
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        let emptyLinks = (1...64)
            .map { "<a href=\"https://example.com/tracker-\($0)\"><img src=\"pixel-\($0).gif\" alt=\"\"></a>" }
            .joined(separator: "\n")

        HTMLContentHandler.shared.saveHTML(
            """
            <!DOCTYPE html>
            <html>
            <body>
              <h1>Daily deals</h1>
              \(emptyLinks)
              <a href="https://example.com/late-action">Late Action</a>
            </body>
            </html>
            """,
            for: messageId
        )

        let loadedSource = await EmailPreviewSourceLoader(htmlContentLoader: HTMLContentLoader()).loadPreviewSource(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: "newsletter@example.com",
            subject: "Daily deals",
            allowRecovery: false
        )
        let source = try XCTUnwrap(loadedSource)

        XCTAssertTrue(source.htmlSummary.actionLinkTexts.isEmpty)
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
