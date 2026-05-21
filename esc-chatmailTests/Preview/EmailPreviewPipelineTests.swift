import XCTest
@testable import esc_chatmail

final class EmailPreviewPipelineTests: XCTestCase {
    private var contentHandler: HTMLContentHandler!
    private var pipeline: EmailPreviewPipeline!

    override func setUp() {
        super.setUp()
        contentHandler = HTMLContentHandler()
        let htmlLoader = HTMLContentLoader(contentHandler: contentHandler, sanitizer: .shared)
        pipeline = EmailPreviewPipeline(
            previewSourceLoader: EmailPreviewSourceLoader(htmlContentLoader: htmlLoader),
            htmlContentLoader: htmlLoader
        )
    }

    override func tearDown() {
        pipeline = nil
        contentHandler = nil
        super.tearDown()
    }

    func testLoadPreview_buildsNewsletterCardFromCanonicalHTML() async throws {
        let messageId = "preview-pipeline-newsletter-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(
            """
            <!DOCTYPE html>
            <html>
            <body>
              <p>View in browser</p>
              <h1>Suites are open for spring stays</h1>
              <img src="https://cdn.example.com/suite.jpg" width="640" height="320" alt="Suite">
              <p>Reserve a quiet room overlooking the city garden.</p>
              <a href="https://example.com/reserve">Reserve now</a>
              <p>Manage Preferences</p>
              <p>Unsubscribe</p>
            </body>
            </html>
            """,
            for: messageId
        )

        let loadedPreview = await pipeline.loadPreview(
            request: EmailPreviewPipelineRequest(
                messageId: messageId,
                bodyStorageURI: nil,
                bodyText: "https://tracking.example.com/open\nSuites are open for spring stays",
                cleanedSnippet: nil,
                senderName: "Reservations",
                senderEmail: "newsletter@example.com",
                subject: "Spring stays",
                isNewsletter: true,
                isForwardedEmail: false,
                cleanupMode: .none,
                isDarkMode: false
            )
        )
        let preview = try XCTUnwrap(loadedPreview)

        guard case .newsletter(let model) = preview else {
            XCTFail("Expected newsletter preview, got \(preview)")
            return
        }

        XCTAssertEqual(model.title, "Suites are open for spring stays")
        XCTAssertEqual(model.heroImageURL, "https://cdn.example.com/suite.jpg")
        XCTAssertFalse(model.snippet.contains("https://tracking.example.com/open"))
    }

    func testLoadPreview_buildsTransactionalCardForAppStoreConnectBuildProcessingEmail() async throws {
        let messageId = "preview-pipeline-app-store-connect-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let subject = "App Store Connect: Version 1.0 (37) for Stickys has completed processing."
        _ = contentHandler.saveHTML(
            """
            <!DOCTYPE html>
            <html>
            <body>
              <table><tr><td>App Store Connect</td></tr></table>
              <table><tr><td>Dear Kevin Thau,</td></tr></table>
              <table><tr><td>Version 1.0 (37) for Stickys has completed processing.</td></tr></table>
              <table>
                <tr><td>App Name:</td><td>Stickys</td></tr>
                <tr><td>Version Number:</td><td>1.0</td></tr>
                <tr><td>Build Number:</td><td>37</td></tr>
              </table>
              <p>You can now use this build for TestFlight testing or submit it to the App Store.</p>
              <p><a href="https://appstoreconnect.apple.com">View in App Store Connect</a></p>
              <p><a href="https://developer.apple.com/contact">Contact us</a></p>
              <p>Privacy Policy | All rights reserved</p>
            </body>
            </html>
            """,
            for: messageId
        )

        let loadedPreview = await pipeline.loadPreview(
            request: EmailPreviewPipelineRequest(
                messageId: messageId,
                bodyStorageURI: nil,
                bodyText: """
                App Store Connect

                Dear Kevin Thau,

                Version 1.0 (37) for Stickys has completed processing.

                App Name: Stickys
                Version Number: 1.0
                Build Number: 37
                """,
                cleanedSnippet: "Dear Kevin Thau,",
                senderName: nil,
                senderEmail: "no_reply@email.apple.com",
                subject: subject,
                isNewsletter: false,
                isForwardedEmail: false,
                cleanupMode: .none,
                isDarkMode: false
            )
        )
        let preview = try XCTUnwrap(loadedPreview)

        guard case .transactional(let model) = preview else {
            XCTFail("Expected transactional preview, got \(preview)")
            return
        }

        XCTAssertEqual(model.title, subject)
        XCTAssertEqual(model.subtitle, "Stickys • Version 1.0 • Build 37")
        XCTAssertEqual(model.status, "Completed")
        XCTAssertEqual(model.sourceLabel, "App Store Connect")
        XCTAssertEqual(model.sourceDomain, "email.apple.com")
    }

    func testLoadPreview_unusableStoredHTMLFallsBackToPlainTextPreview() async throws {
        let messageId = "preview-pipeline-plain-fallback-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(
            """
            <html><body><div style="display: none;">Tracking shell</div></body></html>
            """,
            for: messageId
        )

        let loadedPreview = await pipeline.loadPreview(
            request: EmailPreviewPipelineRequest(
                messageId: messageId,
                bodyStorageURI: nil,
                bodyText: "Invoice paid\nhttps://example.com/receipt",
                cleanedSnippet: nil,
                senderName: "Billing",
                senderEmail: "billing@example.com",
                subject: "Invoice paid",
                isNewsletter: false,
                isForwardedEmail: true,
                cleanupMode: .none,
                isDarkMode: false
            )
        )
        let preview = try XCTUnwrap(loadedPreview)

        guard case .html(let payload) = preview else {
            XCTFail("Expected HTML fallback preview, got \(preview)")
            return
        }

        XCTAssertTrue(payload.html.contains("Invoice paid"))
        XCTAssertTrue(payload.html.contains("https://example.com/receipt"))
        XCTAssertTrue(payload.previewCacheKey.contains("plainText:"))
    }

    func testLoadPreview_unusableMessageFileKeepsStorageURIHTMLFallback() async throws {
        let messageId = "preview-pipeline-storage-fallback-\(UUID().uuidString)"
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
        try """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>Storage preview content</h1>
          <p>Renderable fallback HTML.</p>
        </body>
        </html>
        """.write(to: storageURL, atomically: true, encoding: .utf8)

        let loadedPreview = await pipeline.loadPreview(
            request: EmailPreviewPipelineRequest(
                messageId: messageId,
                bodyStorageURI: storageURL.path,
                bodyText: "https://tracking.example.com/open\nStorage preview content",
                cleanedSnippet: nil,
                senderName: "Sender",
                senderEmail: "sender@example.com",
                subject: "Storage",
                isNewsletter: false,
                isForwardedEmail: true,
                cleanupMode: .none,
                isDarkMode: false
            )
        )
        let preview = try XCTUnwrap(loadedPreview)

        guard case .html(let payload) = preview else {
            XCTFail("Expected storage HTML fallback preview, got \(preview)")
            return
        }

        XCTAssertTrue(payload.html.contains("Storage preview content"))
        XCTAssertFalse(payload.previewCacheKey.contains("plainText:"))
    }
}
