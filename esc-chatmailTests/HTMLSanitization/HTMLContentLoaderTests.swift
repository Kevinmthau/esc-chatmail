import XCTest
@testable import esc_chatmail

final class HTMLContentLoaderTests: XCTestCase {
    private var contentHandler: HTMLContentHandler!
    private var loader: HTMLContentLoader!
    private let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2foAAAAASUVORK5CYII=")!

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

    func testLoadContent_cacheSeparatesPreviewAndOriginalDisplayPurposes() async {
        let messageId = "html-loader-purpose-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let html = """
        <p><a href="https://example.com/deck.pdf">Deck</a></p>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let preview = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )
        let original = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        XCTAssertTrue(preview.html?.contains("text-decoration: inherit") == true)
        XCTAssertFalse(original.html?.contains("text-decoration: inherit") == true)
    }

    func testLoadContent_cacheSeparatesLightAndDarkPreviewVariants() async {
        let messageId = "html-loader-theme-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let html = """
        <p>Theme-sensitive preview</p>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let light = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )
        let dark = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: true,
            cleanupMode: .none,
            displayPurpose: .preview
        )
        let lightReload = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )

        XCTAssertTrue(light.html?.contains("background-color: #f2f2f7") == true)
        XCTAssertTrue(dark.html?.contains("background-color: #1c1c1e") == true)
        XCTAssertTrue(lightReload.html?.contains("background-color: #f2f2f7") == true)
        XCTAssertFalse(lightReload.html?.contains("background-color: #1c1c1e") == true)
    }

    func testLoadContent_cacheInvalidatesWhenMessageHTMLChangesWithoutManualInvalidation() async {
        let messageId = "html-loader-source-signature-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML("<html><body><p>FIRST_SOURCE_TOKEN</p></body></html>", for: messageId)

        let first = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )

        _ = contentHandler.saveHTML("<html><body><p>SECOND_SOURCE_TOKEN</p></body></html>", for: messageId)

        let second = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )

        XCTAssertEqual(first.source, .messageId)
        XCTAssertEqual(second.source, .messageId)
        XCTAssertTrue(first.html?.contains("FIRST_SOURCE_TOKEN") == true)
        XCTAssertFalse(first.html?.contains("SECOND_SOURCE_TOKEN") == true)
        XCTAssertTrue(second.html?.contains("SECOND_SOURCE_TOKEN") == true)
        XCTAssertFalse(second.html?.contains("FIRST_SOURCE_TOKEN") == true)
    }

    func testLoadContent_cacheDoesNotReturnStaleHTMLAfterCurrentSourceRejected() async {
        let messageId = "html-loader-rejected-source-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML("<html><body><p>STALE_CACHE_TOKEN</p></body></html>", for: messageId)

        let cached = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Plain fallback token",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )

        _ = contentHandler.saveHTML(
            """
            <html><body><div style="display: none;">Rejected current source</div></body></html>
            """,
            for: messageId
        )

        let fallback = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Plain fallback token",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )

        XCTAssertEqual(cached.source, .messageId)
        XCTAssertTrue(cached.html?.contains("STALE_CACHE_TOKEN") == true)
        XCTAssertEqual(fallback.source, .plainTextFallback)
        XCTAssertTrue(fallback.html?.contains("Plain fallback token") == true)
        XCTAssertFalse(fallback.html?.contains("STALE_CACHE_TOKEN") == true)
#if DEBUG
        XCTAssertEqual(loader.debugCachedVariantCount(for: messageId), 0)
#endif
    }

    func testLoadContent_invalidatesRejectedMessageCacheBeforeReturningStorageFallback() async throws {
        let messageId = "html-loader-rejected-storage-fallback-\(UUID().uuidString)"
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("html-loader-storage-fallback-\(UUID().uuidString).html")

        defer {
            contentHandler.deleteHTML(for: messageId)
            try? FileManager.default.removeItem(at: storageURL)
        }

        _ = contentHandler.saveHTML("<html><body><p>STALE_CACHE_TOKEN</p></body></html>", for: messageId)

        let lightCached = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Plain fallback token",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )
        let darkCached = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Plain fallback token",
            isDarkMode: true,
            cleanupMode: .none,
            displayPurpose: .preview
        )

        _ = contentHandler.saveHTML(
            """
            <html><body><div style="display: none;">Rejected current source</div></body></html>
            """,
            for: messageId
        )
        try "<html><body><p>STORAGE_FALLBACK_TOKEN</p></body></html>"
            .write(to: storageURL, atomically: true, encoding: .utf8)

        let storageFallback = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: storageURL.absoluteString,
            bodyText: "Plain fallback token",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )

        contentHandler.deleteHTML(for: messageId)
        try FileManager.default.removeItem(at: storageURL)

        let laterFallback = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: storageURL.absoluteString,
            bodyText: "Plain fallback token",
            isDarkMode: true,
            cleanupMode: .none,
            displayPurpose: .preview
        )

        XCTAssertEqual(lightCached.source, .messageId)
        XCTAssertEqual(darkCached.source, .messageId)
        XCTAssertTrue(darkCached.html?.contains("STALE_CACHE_TOKEN") == true)
        XCTAssertEqual(storageFallback.source, .storageURI)
        XCTAssertTrue(storageFallback.html?.contains("STORAGE_FALLBACK_TOKEN") == true)
        XCTAssertFalse(storageFallback.html?.contains("STALE_CACHE_TOKEN") == true)
        XCTAssertEqual(laterFallback.source, .plainTextFallback)
        XCTAssertTrue(laterFallback.html?.contains("Plain fallback token") == true)
        XCTAssertFalse(laterFallback.html?.contains("STALE_CACHE_TOKEN") == true)
    }

    func testLoadContent_keepsStorageFallbackCacheWhenMessageIdSourceRemainsRejected() async throws {
        let messageId = "html-loader-rejected-storage-cache-\(UUID().uuidString)"
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("html-loader-storage-cache-\(UUID().uuidString).html")

        defer {
            contentHandler.deleteHTML(for: messageId)
            try? FileManager.default.removeItem(at: storageURL)
        }

        _ = contentHandler.saveHTML(
            """
            <html><body><div style="display: none;">Rejected current source</div></body></html>
            """,
            for: messageId
        )

        try """
        <!DOCTYPE html>
        <html>
        <body>
          <img src="https://cdn.example.com/banner.jpg?format=webp&width=600" alt="Banner">
          <p>STORAGE_FALLBACK_TOKEN</p>
        </body>
        </html>
        """.write(to: storageURL, atomically: true, encoding: .utf8)

        let recorder = RequestRecorder()
        let imageData = onePixelPNG
        let remoteImageFallback = HTMLRemoteImageAttachmentFallback(
            requestExecutor: { request in
                await recorder.record(request)

                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Type": "image/webp",
                            "Content-Disposition": "inline; filename=\"hero.webp\"",
                            "Content-Length": "\(imageData.count)"
                        ]
                    )
                )

                if request.httpMethod == "HEAD" {
                    return (Data(), response)
                }

                return (imageData, response)
            },
            rewrittenDataURLCacheMaxEntries: 1,
            rewrittenDataURLCacheMaxBytes: 1
        )

        loader = HTMLContentLoader(
            contentHandler: contentHandler,
            sanitizer: .shared,
            remoteImageAttachmentFallback: remoteImageFallback
        )

        let first = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: storageURL.absoluteString,
            senderEmail: "sender@example.com",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        let second = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: storageURL.absoluteString,
            senderEmail: "sender@example.com",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        XCTAssertEqual(first.source, .storageURI)
        XCTAssertEqual(second.source, .storageURI)
        XCTAssertTrue((second.html ?? "").contains("STORAGE_FALLBACK_TOKEN"))
        XCTAssertTrue((second.html ?? "").contains("src=\"data:image/"))

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.methods, ["HEAD", "GET"])
    }

    func testLoadContent_rejectedMessageIdWithMissingStorageDropsStaleStorageCache() async throws {
        let messageId = "html-loader-rejected-missing-storage-\(UUID().uuidString)"
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("html-loader-missing-storage-\(UUID().uuidString).html")

        defer {
            contentHandler.deleteHTML(for: messageId)
            try? FileManager.default.removeItem(at: storageURL)
        }

        try "<html><body><p>STALE_STORAGE_TOKEN</p></body></html>"
            .write(to: storageURL, atomically: true, encoding: .utf8)

        let cachedStorage = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: storageURL.absoluteString,
            bodyText: "Plain fallback token",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )

        try FileManager.default.removeItem(at: storageURL)
        _ = contentHandler.saveHTML(
            """
            <html><body><div style="display: none;">Rejected current source</div></body></html>
            """,
            for: messageId
        )

        let rejectedFallback = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: storageURL.absoluteString,
            bodyText: "Plain fallback token",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )

        contentHandler.deleteHTML(for: messageId)

        let laterFallback = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: storageURL.absoluteString,
            bodyText: "Plain fallback token",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )

        XCTAssertEqual(cachedStorage.source, .storageURI)
        XCTAssertTrue(cachedStorage.html?.contains("STALE_STORAGE_TOKEN") == true)
        XCTAssertEqual(rejectedFallback.source, .plainTextFallback)
        XCTAssertTrue(rejectedFallback.html?.contains("Plain fallback token") == true)
        XCTAssertFalse(rejectedFallback.html?.contains("STALE_STORAGE_TOKEN") == true)
        XCTAssertEqual(laterFallback.source, .plainTextFallback)
        XCTAssertTrue(laterFallback.html?.contains("Plain fallback token") == true)
        XCTAssertFalse(laterFallback.html?.contains("STALE_STORAGE_TOKEN") == true)
#if DEBUG
        XCTAssertEqual(loader.debugCachedVariantCount(for: messageId), 0)
#endif
    }

    func testLoadContent_cacheInvalidatesWhenStorageURISourceChangesWithoutManualInvalidation() async throws {
        let messageId = "html-loader-storage-signature-\(UUID().uuidString)"
        let firstStorageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("html-loader-storage-first-\(UUID().uuidString).html")
        let secondStorageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("html-loader-storage-second-\(UUID().uuidString).html")

        defer {
            try? FileManager.default.removeItem(at: firstStorageURL)
            try? FileManager.default.removeItem(at: secondStorageURL)
        }

        try "<html><body><p>FIRST_STORAGE_TOKEN</p></body></html>"
            .write(to: firstStorageURL, atomically: true, encoding: .utf8)
        try "<html><body><p>SECOND_STORAGE_TOKEN</p></body></html>"
            .write(to: secondStorageURL, atomically: true, encoding: .utf8)

        let first = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: firstStorageURL.absoluteString,
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )

        let second = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: secondStorageURL.absoluteString,
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )

        XCTAssertEqual(first.source, .storageURI)
        XCTAssertEqual(second.source, .storageURI)
        XCTAssertTrue(first.html?.contains("FIRST_STORAGE_TOKEN") == true)
        XCTAssertFalse(first.html?.contains("SECOND_STORAGE_TOKEN") == true)
        XCTAssertTrue(second.html?.contains("SECOND_STORAGE_TOKEN") == true)
        XCTAssertFalse(second.html?.contains("FIRST_STORAGE_TOKEN") == true)
    }

    func testPreparePreviewHTML_wrapsKnownCanonicalHTMLWithoutReloadingSources() async {
        let previewHTML = await loader.preparePreviewHTML(
            fromCanonicalHTML: """
            <html>
            <body>
              <p>Canonical preview body</p>
            </body>
            </html>
            """,
            messageId: "html-loader-known-canonical-\(UUID().uuidString)",
            bodyText: nil,
            senderEmail: "sender@example.com",
            subject: "Subject",
            isDarkMode: false,
            cleanupMode: .none
        )

        XCTAssertNotNil(previewHTML)
        XCTAssertTrue(previewHTML?.contains("Canonical preview body") == true)
        XCTAssertTrue(previewHTML?.contains("background-color: #f2f2f7") == true)
    }

    func testPrepareOriginalHTMLCachesPreparedOriginalHTML() async {
        let messageId = "html-loader-original-canonical-cache-\(UUID().uuidString)"
        let originalHTML = """
        <!DOCTYPE html>
        <html>
        <body>
          <table><tr><td>Canonical original body</td></tr></table>
        </body>
        </html>
        """

        let first = await loader.prepareOriginalHTML(
            fromCanonicalHTML: originalHTML,
            messageId: messageId,
            sourceLocation: .messageFile,
            plainText: nil,
            senderEmail: "sender@example.com",
            subject: "Subject",
            isDarkMode: false
        )
        let second = await loader.prepareOriginalHTML(
            fromCanonicalHTML: originalHTML,
            messageId: messageId,
            sourceLocation: .messageFile,
            plainText: nil,
            senderEmail: "sender@example.com",
            subject: "Subject",
            isDarkMode: false
        )

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first?.contains("Canonical original body") == true)
#if DEBUG
        XCTAssertEqual(loader.debugCachedVariantCount(for: messageId), 1)
#endif
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

    func testLoadContent_plainTextFallback_rawEmailSourceWithPreviewPadding_stillShowsContent() async {
        let messageId = "html-loader-raw-source-\(UUID().uuidString)"
        let bodyText = """
        Delivered-To: person@example.com
        Received: by 2002:a05:6e04:71a:b0:3ac:63b9:5e27 with SMTP id o26csp2106356imz;
        X-Received: by 2002:ac8:7dd4:0:b0:503:4257:da03 with SMTP id d75a77;
        DKIM-Signature: v=1; a=rsa-sha256; d=inform.bill.com;
        Mime-Version: 1.0
        Content-Type: multipart/alternative; boundary=abc123

        --abc123
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Sign in to approve this bill. =E2=80=8C =C2=A0 =E2=80=8C =C2=A0 =E2=80=8C =C2=A0 =E2=80=8C =C2=A0 =E2=80=8C =C2=A0 =E2=80=8C =C2=A0

        Vendor
        Law Office of Kristine A. Sova, PLLC

        Amount
        $3,844.50

        Approve bill
        --abc123--
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
        XCTAssertTrue(html.contains("Sign in to approve this bill."))
        XCTAssertTrue(html.contains("Law Office of Kristine A. Sova, PLLC"))
        XCTAssertFalse(html.contains("\u{200C}"))
    }

    func testLoadContent_rawEmailSourceWithEmbeddedHTML_prefersExtractedHTMLPart() async {
        let messageId = "html-loader-raw-html-\(UUID().uuidString)"
        let bodyText = """
        Delivered-To: person@example.com
        Received: by 2002:a05:6e04:71a:b0:3ac:63b9:5e27 with SMTP id o26csp2106356imz;
        X-Received: by 2002:ac8:7dd4:0:b0:503:4257:da03 with SMTP id d75a77;
        Return-Path: <newsletter@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="newsletter-boundary-123"

        --newsletter-boundary-123
        Content-Type: text/plain; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable

        Example Museum
        View in Browser
        Tickets are now on sale for the Spring Documentary Festival
        Learn More
        Unsubscribe

        --newsletter-boundary-123
        Content-Type: text/html; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable

        <!DOCTYPE html>
        <html>
        <body>
          <table role=3D"presentation" width=3D"100%">
            <tr>
              <td>
                <p>View in Browser</p>
                <h1>Tickets are now on sale for the Spring Documentary Festival</h1>
                <p>Join us for a showcase of outstanding documentary films and immersive conversations around the world.</p>
                <table role=3D"presentation">
                  <tr><td><a href=3D"https://example.com/learn-more">Learn More</a></td></tr>
                </table>
                <p><a href=3D"https://example.com/unsubscribe">Unsubscribe</a> | <a href=3D"https://example.com/preferences">Manage Preferences</a></p>
              </td>
            </tr>
          </table>
        </body>
        </html>

        --newsletter-boundary-123--
        """

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: bodyText,
            isDarkMode: false,
            cleanupMode: .none
        )

        guard case .rawSourceHTML = result.source else {
            XCTFail("Expected rawSourceHTML source")
            return
        }

        let html = result.html ?? ""
        XCTAssertTrue(html.contains("Tickets are now on sale for the Spring Documentary Festival"))
        XCTAssertTrue(html.contains("Manage Preferences"))
        XCTAssertFalse(html.contains("Delivered-To:"))
    }

    func testLoadContent_originalDisplay_prefersStoredWordFlyHTMLOverPlainTextFallback() async {
        let messageId = "html-loader-wordfly-original-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(wordFlyRecoveredHTML, for: messageId)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: wordFlyPlainTextFallback,
            senderEmail: "publicprograms@email.amnh.org",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        guard case .messageId = result.source else {
            XCTFail("Expected stored HTML source, got \(result.source)")
            return
        }

        let html = result.html ?? ""
        XCTAssertEqual(result.presentation, .html)
        XCTAssertNil(result.nativeText)
        XCTAssertTrue(html.contains("Tickets are now on sale for the 2026 Margaret Mead Film Festival"))
        XCTAssertTrue(html.contains("Festival Films Include"))
        XCTAssertFalse(html.contains("<summary>See More</summary>"))
    }

    func testLoadContent_originalDisplay_fallsBackToReadableTextForDegradedTransactionalHTML() async {
        let messageId = "html-loader-degraded-transactional-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(degradedTransactionalHTML, for: messageId)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: degradedTransactionalPlainText,
            senderEmail: "alerts@cnb.com",
            subject: "Zelle payment alert",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        guard case .qualityFallback = result.source else {
            XCTFail("Expected qualityFallback source, got \(result.source)")
            return
        }

        XCTAssertEqual(result.presentation, .nativePlainText)
        XCTAssertNil(result.html)
        XCTAssertTrue(result.nativeText?.contains("Andrew Archer sent you $100.00.") == true)
        XCTAssertTrue(result.nativeText?.contains("https://example.com/open") == true)
    }

    func testLoadContent_originalDisplay_keepsModeratelyComplexTestFlightHTML() async {
        let messageId = "html-loader-testflight-original-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let detailTables = (1...10)
            .map { "<table width=\"100%\"><tr><td>Build detail row \($0)</td></tr></table>" }
            .joined(separator: "\n")
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
          <table width="100%"><tr><td>Inbox chat 1.0 (129) is ready to test on iOS.</td></tr></table>
          \(detailTables)
          <table width="100%"><tr><td><a href="https://testflight.apple.com/v1/app/123">Open TestFlight</a></td></tr></table>
        </body>
        </html>
        """
        let bodyText = """
        Inbox chat 1.0 (129) is ready to test on iOS.
        Build detail row 1
        Build detail row 2
        Build detail row 3
        Build detail row 4
        Build detail row 5
        Open TestFlight
        https://testflight.apple.com/v1/app/123
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: bodyText,
            senderEmail: "testflight_no_reply@email.apple.com",
            subject: "Inbox chat 1.0 (129) for iOS is now available to test.",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        XCTAssertEqual(result.presentation, .html)
        XCTAssertNil(result.nativeText)
        XCTAssertTrue(result.html?.contains("Inbox chat 1.0 (129) is ready to test on iOS.") == true)
    }

    func testLoadReplyQuotedOriginalHTML_returnsSanitizedHTML() {
        let messageId = "html-loader-reply-sanitized-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let html = """
        <!DOCTYPE html>
        <html>
        <body>
          <img src="https://track.example.com/open.php?message=123" width="1" height="1" alt="">
          <p>Visible body text</p>
          <script>alert('xss')</script>
        </body>
        </html>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let result = loader.loadReplyQuotedOriginalHTML(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Visible body text",
            senderEmail: "sender@example.com",
            subject: "Hello"
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("Visible body text") == true)
        XCTAssertFalse(result?.contains("track.example.com") == true)
        XCTAssertFalse(result?.lowercased().contains("<script") == true)
    }

    func testLoadContent_previewDisplay_keepsTransactionalHTMLWhenOriginalDisplayFallsBack() async {
        let messageId = "html-loader-degraded-preview-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(degradedTransactionalHTML, for: messageId)

        let previewResult = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: degradedTransactionalPlainText,
            senderEmail: "alerts@cnb.com",
            subject: "Zelle payment alert",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .preview
        )

        let originalResult = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: degradedTransactionalPlainText,
            senderEmail: "alerts@cnb.com",
            subject: "Zelle payment alert",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        XCTAssertEqual(previewResult.presentation, .html)
        XCTAssertNotNil(previewResult.html)
        XCTAssertTrue(previewResult.html?.contains("View Payment") == true)

        XCTAssertEqual(originalResult.presentation, .nativePlainText)
        XCTAssertNil(originalResult.html)
        XCTAssertTrue(originalResult.nativeText?.contains("Andrew Archer sent you $100.00.") == true)
    }

    func testLoadContent_originalDisplay_keepsResponsiveHTMLWhenOnlyHeadMarkupIsHeavy() async {
        let messageId = "html-loader-responsive-head-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let responsiveCSS = (0..<160).map { index in
            """
            @media only screen and (max-width: 600px) {
              .stack-\(index) { display: block !important; width: 100% !important; }
              .pad-\(index) { padding-left: \(index % 12)px !important; padding-right: \(index % 10)px !important; }
            }
            """
        }.joined(separator: "\n")

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
          <style>
          \(responsiveCSS)
          </style>
        </head>
        <body>
          <table width="100%"><tr><td><strong>Your monthly statement is ready.</strong></td></tr></table>
          <table width="100%"><tr><td>Review the latest activity in the secure message center.</td></tr></table>
        </body>
        </html>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: """
            Example Bank account update

            Your monthly statement is ready.
            Review the latest activity in the secure message center.
            """,
            senderEmail: "alerts@examplebank.com",
            subject: "Statement ready",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        XCTAssertEqual(result.presentation, .html)
        XCTAssertNotNil(result.html)
        XCTAssertTrue(result.html?.contains("Your monthly statement is ready.") == true)
    }

    func testLoadContent_originalDisplay_garmentoryFixtureDoesNotDisableShrinkToFit() async throws {
        let messageId = "html-loader-garmentory-original-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let garmentoryHTML = try loadFixture(named: "garmentory_lower_prices.html")
        _ = contentHandler.saveHTML(garmentoryHTML, for: messageId)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: "hello@m.garmentory.com",
            subject: "NEW LOWER PRICES",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        guard case .messageId = result.source else {
            XCTFail("Expected stored HTML source, got \(result.source)")
            return
        }

        let html = try XCTUnwrap(result.html)
        XCTAssertEqual(result.presentation, .html)
        XCTAssertEqual(html.components(separatedBy: "<meta name=\"viewport\"").count - 1, 1)
        XCTAssertFalse(html.contains("shrink-to-fit=no"))
        XCTAssertTrue(html.contains("@media(max-width:620px){.mobile_hide{display:none}.row-content{width:100%!important}"))
        XCTAssertTrue(html.contains("class=\"block-grid two-up no-stack\""))
        XCTAssertTrue(html.contains("min-width: 300px; width: 300px;"))
    }

    func testLoadContent_originalDisplay_hiddenCTAContentTriggersReadableFallback() async {
        let messageId = "html-loader-hidden-cta-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        _ = contentHandler.saveHTML(hiddenCTAHTML, for: messageId)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: hiddenCTAPlainText,
            senderEmail: "security@examplebank.com",
            subject: "Verify your login",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        XCTAssertEqual(result.presentation, .nativePlainText)
        XCTAssertTrue(result.nativeText?.contains("Use this verification code: 482913") == true)
    }

    func testLoadContent_cachedStorageURIResultPreservesSource() async throws {
        let messageId = "html-loader-storage-cache-\(UUID().uuidString)"
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("html-loader-storage-\(UUID().uuidString).html")

        defer {
            try? FileManager.default.removeItem(at: storageURL)
        }

        try """
        <!DOCTYPE html>
        <html>
        <body>
          <p>Stored HTML token</p>
        </body>
        </html>
        """.write(to: storageURL, atomically: true, encoding: .utf8)

        let first = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: storageURL.absoluteString,
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        XCTAssertEqual(first.source, .storageURI)
        XCTAssertEqual(first.presentation, .html)

        try FileManager.default.removeItem(at: storageURL)

        let second = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: storageURL.absoluteString,
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        XCTAssertEqual(second.source, .storageURI)
        XCTAssertEqual(second.presentation, .html)
        XCTAssertTrue(second.html?.contains("Stored HTML token") == true)
    }

    func testLoadContent_originalAutomaticCacheReevaluatesWhenReadableFallbackInputsChange() async {
        let messageId = "html-loader-metadata-cache-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
          <style>
            .primaryCTA { display: none; }
          </style>
        </head>
        <body>
          <table width="100%"><tr><td align="center"><img src="https://example.com/logo.png" alt="Example Bank" width="180"></td></tr></table>
          <table width="100%"><tr><td height="64">&nbsp;</td></tr></table>
          <table width="100%"><tr><td>A new notice is available in your secure inbox.</td></tr></table>
          <table class="primaryCTA" width="100%"><tr><td><a href="https://example.com/verify">Open notice</a></td></tr></table>
        </body>
        </html>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let initial = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            senderEmail: nil,
            subject: nil,
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        XCTAssertEqual(initial.presentation, .html)
        XCTAssertNotNil(initial.html)

        let hydrated = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: hiddenCTAPlainText,
            senderEmail: "alerts@examplebank.com",
            subject: "Security alert",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        XCTAssertEqual(hydrated.source, .qualityFallback)
        XCTAssertEqual(hydrated.presentation, .nativePlainText)
        XCTAssertTrue(hydrated.nativeText?.contains("Use this verification code: 482913") == true)
    }

    func testLoadContent_originalDisplay_rawSourceWithDuplicatePlainTextPartsFallsBackToReadableText() async {
        let messageId = "html-loader-duplicate-plain-\(UUID().uuidString)"

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: duplicatedPlainTextTransactionalRawSource,
            senderEmail: "alerts@cnb.com",
            subject: "Zelle payment alert",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        XCTAssertEqual(result.presentation, .nativePlainText)
        XCTAssertTrue(result.nativeText?.contains("Andrew Archer sent you $100.00.") == true)
        XCTAssertFalse(result.nativeText?.contains("Content-Type: text/plain") == true)
    }

    func testLoadContent_rawWordFlySource_originalDisplay_prefersExtractedHTMLPart() async {
        let messageId = "html-loader-wordfly-raw-source-\(UUID().uuidString)"

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: wordFlyRawSource,
            senderEmail: "publicprograms@email.amnh.org",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        guard case .rawSourceHTML = result.source else {
            XCTFail("Expected rawSourceHTML source, got \(result.source)")
            return
        }

        let html = result.html ?? ""
        XCTAssertEqual(result.presentation, .html)
        XCTAssertNil(result.nativeText)
        XCTAssertTrue(html.contains("Tickets are now on sale for the 2026 Margaret Mead Film Festival"))
        XCTAssertTrue(html.contains("Festival Films Include"))
        XCTAssertFalse(html.contains("<summary>See More</summary>"))
    }

    func testLoadContent_ignoresStaleStoredPlainTextFallbackHTMLAndUsesRealHTMLSource() async throws {
        let messageId = "html-loader-stale-fallback-\(UUID().uuidString)"
        let staleFallbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-fallback-\(UUID().uuidString).html")

        defer {
            try? FileManager.default.removeItem(at: staleFallbackURL)
        }

        try staleStoredFallbackHTML.write(to: staleFallbackURL, atomically: true, encoding: .utf8)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: staleFallbackURL.absoluteString,
            bodyText: wordFlyRawSource,
            senderEmail: "publicprograms@email.amnh.org",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        guard case .rawSourceHTML = result.source else {
            XCTFail("Expected rawSourceHTML source, got \(result.source)")
            return
        }

        let html = result.html ?? ""
        XCTAssertTrue(html.contains("Tickets are now on sale for the 2026 Margaret Mead Film Festival"))
        XCTAssertTrue(html.contains("Festival Films Include"))
        XCTAssertFalse(html.contains("<summary>See More</summary>"))
    }

    func testLoadContent_plainTextFallback_onlyInvisiblePadding_returnsNotFound() async {
        let messageId = "html-loader-invisible-only-\(UUID().uuidString)"
        let bodyText = String(repeating: "\u{200C}\u{00A0}", count: 400)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: bodyText,
            isDarkMode: false,
            cleanupMode: .none
        )

        guard case .notFound = result.source else {
            XCTFail("Expected notFound source")
            return
        }

        XCTAssertNil(result.html)
    }

    func testLoadContent_hiddenPreviewMarkupOnly_returnsNotFound() async {
        let messageId = "html-loader-hidden-only-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
          <style>
            .m-hide { display: none !important; }
          </style>
        </head>
        <body>
          <table>
            <tr class="m-hide" style="mso-hide: all;">
              <td style="font-size:0pt; line-height:0pt;">
                Sign in to approve this bill.
              </td>
            </tr>
          </table>
        </body>
        </html>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            isDarkMode: false,
            cleanupMode: .quotedAndSignature
        )

        guard case .notFound = result.source else {
            XCTFail("Expected notFound source for hidden-only HTML")
            return
        }
        XCTAssertNil(result.html)
    }

    func testLoadContent_hiddenPreviewMarkupWithVisibleBody_returnsVisibleResult() async {
        let messageId = "html-loader-hidden-plus-visible-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
          <style>
            .m-hide { display: none !important; }
          </style>
        </head>
        <body>
          <table>
            <tr class="m-hide" style="mso-hide: all;">
              <td style="font-size:0pt; line-height:0pt;">
                Sign in to approve this bill.
              </td>
            </tr>
          </table>
          <div>
            <p>A bill for Law Office of Kristine A. Sova, PLLC needs your approval.</p>
            <p>Amount $3,844.50</p>
          </div>
        </body>
        </html>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            isDarkMode: false,
            cleanupMode: .quotedAndSignature
        )

        XCTAssertNotNil(result.html)
        XCTAssertTrue((result.html ?? "").contains("needs your approval"))
        XCTAssertTrue((result.html ?? "").contains("$3,844.50"))
    }

    func testLoadContent_visibleContentInsideZeroFontWrapper_isNotDiscarded() async {
        let messageId = "html-loader-zero-font-wrapper-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let html = """
        <!DOCTYPE html>
        <html>
        <body>
          <table width="640">
            <tr>
              <td style="width:640px; min-width:640px; font-size:0pt; line-height:0pt; padding:0; margin:0;">
                <table width="100%">
                  <tr>
                    <td style="font-size:16px; line-height:24px;">
                      <strong>A bill for Example Vendor LLC needs your approval</strong>
                    </td>
                  </tr>
                </table>
              </td>
            </tr>
          </table>
        </body>
        </html>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            isDarkMode: false,
            cleanupMode: .quotedAndSignature
        )

        XCTAssertNotNil(result.html)
        XCTAssertTrue((result.html ?? "").contains("needs your approval"))
    }

    func testLoadContentWithTimeout_returnsLocalHTMLWhileRemoteFallbackWarmsInBackground() async {
        let messageId = "html-loader-timeout-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let imageData = onePixelPNG
        let remoteImageFallback = HTMLRemoteImageAttachmentFallback { request in
            try? await Task.sleep(nanoseconds: 250_000_000)

            let headers = [
                "Content-Type": "image/png",
                "Content-Disposition": "attachment; filename=\"banner.png\"",
                "Content-Length": "\(imageData.count)"
            ]

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com/open.php")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: headers
            )!

            if request.httpMethod == "HEAD" {
                return (Data(), response)
            }

            return (imageData, response)
        }

        loader = HTMLContentLoader(
            contentHandler: contentHandler,
            sanitizer: .shared,
            remoteImageAttachmentFallback: remoteImageFallback
        )

        let html = """
        <html>
        <body>
          <img src="https://cdn.example.com/open.php?id=slow-banner" alt="Banner">
          <p>Visible body text</p>
        </body>
        </html>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let result = await loader.loadContentWithTimeout(
            messageId: messageId,
            bodyStorageURI: nil,
            senderEmail: "sender@example.com",
            isDarkMode: false,
            cleanupMode: .none,
            timeout: 0.05
        )

        guard case .messageId = result.source else {
            XCTFail("Expected fast local HTML render instead of timeout fallback")
            return
        }

        XCTAssertNotNil(result.html)
        XCTAssertTrue((result.html ?? "").contains("Visible body text"))
    }

    func testLoadContent_sanitizesTrackingPixelsBeforeRemoteFallbackWarmup() async {
        let messageId = "html-loader-tracking-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let recorder = RequestRecorder()
        let remoteImageFallback = HTMLRemoteImageAttachmentFallback { request in
            await recorder.record(request)
            return (
                Data(),
                HTTPURLResponse(
                    url: request.url ?? URL(string: "https://track.example.com/open.php")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        loader = HTMLContentLoader(
            contentHandler: contentHandler,
            sanitizer: .shared,
            remoteImageAttachmentFallback: remoteImageFallback
        )

        let html = """
        <html>
        <body>
          <img src="https://track.example.com/open.php?message=123" width="1" height="1" alt="">
          <p>Visible body text</p>
        </body>
        </html>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            senderEmail: "sender@example.com",
            isDarkMode: false,
            cleanupMode: .none
        )

        XCTAssertNotNil(result.html)
        XCTAssertTrue((result.html ?? "").contains("Visible body text"))
        XCTAssertFalse((result.html ?? "").contains("track.example.com"))

        try? await Task.sleep(nanoseconds: 50_000_000)

        let snapshot = await recorder.snapshot()
        XCTAssertTrue(snapshot.methods.isEmpty)
    }

    func testLoadContent_warmsAttachmentStyleRemoteImagesAfterInitialRender() async throws {
        let messageId = "html-loader-remote-attachment-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let recorder = RequestRecorder()
        let imageData = onePixelPNG
        let remoteImageFallback = HTMLRemoteImageAttachmentFallback { request in
            await recorder.record(request)

            let headers = [
                "Content-Type": "image/png",
                "Content-Disposition": "attachment; filename=\"Brambles_Banner.png\"",
                "Content-Length": "\(imageData.count)"
            ]

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: headers
                )
            )

            if request.httpMethod == "HEAD" {
                return (Data(), response)
            }

            return (imageData, response)
        }

        loader = HTMLContentLoader(
            contentHandler: contentHandler,
            sanitizer: .shared,
            remoteImageAttachmentFallback: remoteImageFallback
        )

        let warmNotification = expectation(description: "Remote image fallback warm notification")
        let observer = NotificationCenter.default.addObserver(
            forName: HTMLContentLoader.remoteImageAttachmentFallbackDidWarmNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard notification.userInfo?[HTMLContentLoader.remoteImageAttachmentFallbackMessageIdUserInfoKey] as? String == messageId else {
                return
            }
            warmNotification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let html = """
        <!DOCTYPE html>
        <html>
        <body>
          <img src="https://d3t000000dywoeaq.file.force.com/file-asset-public/Brambles_Banner?oid=00D3t000000dywO" alt="Banner">
          <p>Visible body text</p>
        </body>
        </html>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            senderEmail: "thomas@brambles.golf",
            isDarkMode: false,
            cleanupMode: .none
        )

        XCTAssertNotNil(result.html)
        XCTAssertTrue((result.html ?? "").contains("Visible body text"))
        XCTAssertFalse((result.html ?? "").contains("src=\"data:image/"))

        await fulfillment(of: [warmNotification], timeout: 1.0)

        for _ in 0..<20 {
            let snapshot = await recorder.snapshot()
            if snapshot.methods == ["HEAD", "GET"] {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        var warmedHTML: String?
        for _ in 0..<20 {
            let warmedResult = await loader.loadContent(
                messageId: messageId,
                bodyStorageURI: nil,
                senderEmail: "thomas@brambles.golf",
                isDarkMode: false,
                cleanupMode: .none
            )

            if let html = warmedResult.html,
               html.contains("src=\"data:image/") {
                warmedHTML = html
                break
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertNotNil(warmedHTML)
        XCTAssertTrue((warmedHTML ?? "").contains("Visible body text"))

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.methods, ["HEAD", "GET"])
        XCTAssertEqual(snapshot.referers, ["https://brambles.golf/", "https://brambles.golf/"])
    }

    func testLoadContent_originalDisplayPurposeRewritesRiskyModernImagesOnFirstRender() async throws {
        let messageId = "html-loader-original-webp-\(UUID().uuidString)"
        defer { contentHandler.deleteHTML(for: messageId) }

        let recorder = RequestRecorder()
        let imageData = onePixelPNG
        let remoteImageFallback = HTMLRemoteImageAttachmentFallback { request in
            await recorder.record(request)

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "image/webp",
                        "Content-Disposition": "inline; filename=\"hero.webp\"",
                        "Content-Length": "\(imageData.count)"
                    ]
                )
            )

            if request.httpMethod == "HEAD" {
                return (Data(), response)
            }

            return (imageData, response)
        }

        loader = HTMLContentLoader(
            contentHandler: contentHandler,
            sanitizer: .shared,
            remoteImageAttachmentFallback: remoteImageFallback
        )

        let html = """
        <!DOCTYPE html>
        <html>
        <body>
          <img src="https://cdn.example.com/banner.jpg?format=webp&width=600" alt="Banner">
          <p>Visible body text</p>
        </body>
        </html>
        """
        _ = contentHandler.saveHTML(html, for: messageId)

        let result = await loader.loadContent(
            messageId: messageId,
            bodyStorageURI: nil,
            senderEmail: "sender@example.com",
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original
        )

        XCTAssertNotNil(result.html)
        XCTAssertTrue((result.html ?? "").contains("Visible body text"))
        XCTAssertTrue((result.html ?? "").contains("src=\"data:image/"))
        XCTAssertFalse((result.html ?? "").contains("format=webp"))

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.methods, ["HEAD", "GET"])
        XCTAssertEqual(snapshot.referers, ["https://example.com/", "https://example.com/"])
    }

    private func loadFixture(named name: String) throws -> String {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestSupport")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)

        return try String(contentsOf: fixtureURL, encoding: .utf8)
    }
}

private actor RequestRecorder {
    private(set) var methods: [String] = []
    private(set) var referers: [String?] = []

    func record(_ request: URLRequest) {
        methods.append(request.httpMethod ?? "")
        referers.append(request.value(forHTTPHeaderField: "Referer"))
    }

    func snapshot() -> (methods: [String], referers: [String?]) {
        (methods, referers)
    }
}

private let wordFlyPlainTextFallback = """
American Museum of Natural History
https://e.wordfly.com/click?sid=NDYwXzk0NzcwXzU4NDU4NjBfNjk3MQ&l=aff23ba9-c62e-f111-a83f-0050569d9d1d

View in Browser
https://e.wordfly.com/view?sid=NDYwXzk0NzcwXzU4NDU4NjBfNjk3MQ&l=aef23ba9-c62e-f111-a83f-0050569d9d1d

Tickets are now on sale for the 2026 Margaret Mead Film Festival
Join us for a showcase of outstanding documentary films.
"""

private let wordFlyRecoveredHTML = """
<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" dir="ltr" lang="en"><head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0, minimum-scale=1.0, maximum-scale=1.0" />
<style type="text/css">
@media only screen and (max-width: 480px) {
  .two-columns-block .column { display: block !important; width: 100% !important; }
}
</style>
<title>American Museum of Natural History</title>
</head><body style="margin:0; min-width:100%; padding:0px 10px 0px 0px; width:100%; background-color:#ffffff; color:#000000;">
<div id="email-container" style="background-color:#ffffff; margin-left:auto; margin-right:auto; padding:15px;">
  <div class="container-block block" style="background-color:#000000;">
    <div class="text-block block" style="padding:5px 10px 10px 25px; margin-top:10px;">
      <p style="margin:0px 0px 12px; font-size:12px; color:#ffffff; line-height:17.6px;">Join us for a showcase of outstanding documentary films. | <a href="https://e.wordfly.com/view?sid=NDYwXzk0NzcwXzU4NDU4NjBfNjk3MQ&l=aef23ba9-c62e-f111-a83f-0050569d9d1d" target="_blank" style="color:#d7fa88;">View in Browser</a></p>
    </div>
  </div>
  <div class="image-block block" style="padding:0px 0px 15px;">
    <a href="https://e.wordfly.com/click?sid=NDYwXzk0NzcwXzU4NDU4NjBfNjk3MQ&l=b0f23ba9-c62e-f111-a83f-0050569d9d1d" target="_blank"><img src="https://media.wordfly.com/americanmuseumofnaturalhistory/emails/260402-pp-mead-on-sale/mead-festival-hero.jpg" alt="A seated audience in the orchestra and balcony of the LeFrak Theater watch the screen." style="width:100%;" /></a>
  </div>
  <div class="text-block block" style="padding:5px 10px 0px;">
    <h1 style="margin:0px; padding:0px 0px 15px; font-size:20px; line-height:32px;">Tickets are now on sale for the 2026 Margaret Mead Film Festival</h1>
    <p style="margin:0px 0px 14px; font-size:14px; line-height:24px;">The Museum’s Margaret Mead Film Festival is back with a showcase of outstanding documentary films.</p>
    <p style="margin:0px 0px 14px; font-size:14px; line-height:24px;">Join us from <b>Friday, May 1—Sunday, May 3</b> for a cinematic celebration of voices and perspectives from around the world.</p>
  </div>
  <div class="button-block block" style="padding:15px 15px 15px 10px;">
    <div style="display:inline-block; padding:10px 25px; background-color:#004bb4;"><a href="https://e.wordfly.com/click?sid=NDYwXzk0NzcwXzU4NDU4NjBfNjk3MQ&l=b0f23ba9-c62e-f111-a83f-0050569d9d1d" target="_blank" style="color:#ffffff; font-size:16px; text-decoration:none;">Learn More</a></div>
  </div>
  <div class="text-block block" style="padding:10px;">
    <h1 style="margin:0px; padding:0px; font-size:20px; line-height:32px;">Festival Films Include:</h1>
  </div>
  <div class="two-columns-block block split-33-66" style="margin-left:5%; margin-right:5%;">
    <div class="column" style="display:inline-block; vertical-align:middle; width:33.3333%;">
      <div class="image-block block" style="padding:15px;">
        <img src="https://media.wordfly.com/americanmuseumofnaturalhistory/emails/260402-pp-mead-on-sale/time-and-water-thumb.jpg" alt="Árni Kjartansson sits on the edge of a cliff overlooking a glacier." style="width:100%;" />
      </div>
    </div>
    <div class="column" style="display:inline-block; vertical-align:middle; width:66.6667%;">
      <div class="text-block block" style="padding:5px 10px 0px;">
        <h3 style="margin:0px 0px 10px; font-size:20px; line-height:20px;">Opening Night: <i><a href="https://e.wordfly.com/click?sid=NDYwXzk0NzcwXzU4NDU4NjBfNjk3MQ&l=b7e0dde4-9632-f111-a83f-0050569d9d1d" target="_blank">Time and Water</a></i></h3>
        <h2 style="margin:10px 0px; font-size:14px; line-height:19.5px; color:#707070;">Directed by Sara Dosa<br />Friday, May 1 | 7 pm</h2>
        <p style="margin:0px 0px 14px; font-size:14px; line-height:24px;">Entrusted with writing a eulogy for Okjökull, the first Icelandic glacier lost to climate change, Andri Snær Magnason embarks on a profound exploration of environmental love and mourning.</p>
      </div>
    </div>
  </div>
</div>
</body></html>
"""

private let wordFlyRawSource = """
Delivered-To: person@example.com
Received: by 2002:ad5:4bcf:0:b0:3b9:5283:f04d with SMTP id v15csp2260452imw;
        Tue, 7 Apr 2026 12:33:01 -0700 (PDT)
X-Received: by 2002:a05:7300:571e:b0:2c6:1557:9997 with SMTP id 5a478bee46e88;
        Tue, 07 Apr 2026 12:33:00 -0700 (PDT)
Return-Path: <museum@example.wordfly.com>
MIME-Version: 1.0
From: Example Museum <publicprograms@example.org>
Subject: Tickets Now On Sale for the Film Festival
Content-Type: multipart/alternative; boundary=--boundary_1481459_example

----boundary_1481459_example
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: quoted-printable

American Museum of Natural History
https://e.wordfly.com/click?sid=3DNDYwXzk0NzcwXzU4NDU4NjBfNjk3MQ&l=3Daff23ba=
9-c62e-f111-a83f-0050569d9d1d

View in Browser
https://e.wordfly.com/view?sid=3DNDYwXzk0NzcwXzU4NDU4NjBfNjk3MQ&l=3Daef23ba=
9-c62e-f111-a83f-0050569d9d1d

Tickets are now on sale for the 2026 Margaret Mead Film Festival
Join us for a showcase of outstanding documentary films.

----boundary_1481459_example
Content-Type: text/html; charset=utf-8
Content-Transfer-Encoding: quoted-printable

<!DOCTYPE html><html xmlns=3D"http://www.w3.org/1999/xhtml" dir=3D"ltr" lang=
=3D"en"><head><meta charset=3D"utf-8" /><meta name=3D"viewport" content=3D"w=
idth=3Ddevice-width, initial-scale=3D1.0, minimum-scale=3D1.0, maximum-scal=
e=3D1.0" /><style type=3D"text/css">@media only screen and (max-width: 480px=
) {.two-columns-block .column { display: block !important; width: 100% !impo=
rtant; }}</style><title>American Museum of Natural History</title></head><bo=
dy style=3D"margin:0; min-width:100%; padding:0px 10px 0px 0px; width:100%; =
background-color:#ffffff; color:#000000;"><div id=3D"email-container" style=
=3D"background-color:#ffffff; margin-left:auto; margin-right:auto; padding:1=
5px;"><div class=3D"container-block block" style=3D"background-color:#000000=
;"><div class=3D"text-block block" style=3D"padding:5px 10px 10px 25px; marg=
in-top:10px;"><p style=3D"margin:0px 0px 12px; font-size:12px; color:#ffffff=
; line-height:17.6px;">Join us for a showcase of outstanding documentary fil=
ms. | <a href=3D"https://e.wordfly.com/view?sid=3DNDYwXzk0NzcwXzU4NDU4NjBfNjk=
3MQ&l=3Daef23ba9-c62e-f111-a83f-0050569d9d1d" target=3D"_blank" style=3D"colo=
r:#d7fa88;">View in Browser</a></p></div></div><div class=3D"text-block bloc=
k" style=3D"padding:5px 10px 0px;"><h1 style=3D"margin:0px; padding:0px 0px =
15px; font-size:20px; line-height:32px;">Tickets are now on sale for the 202=
6 Margaret Mead Film Festival</h1><p style=3D"margin:0px 0px 14px; font-size=
:14px; line-height:24px;">The Museum=E2=80=99s Margaret Mead Film Festival is=
 back with a showcase of outstanding documentary films.</p><p style=3D"margi=
n:0px 0px 14px; font-size:14px; line-height:24px;">Join us from <b>Friday, M=
ay 1=E2=80=94Sunday, May 3</b> for a cinematic celebration of voices and pers=
pectives from around the world.</p></div><div class=3D"text-block block" sty=
le=3D"padding:10px;"><h1 style=3D"margin:0px; padding:0px; font-size:20px; l=
ine-height:32px;">Festival Films Include:</h1></div></div></body></html>

----boundary_1481459_example--
"""

private let staleStoredFallbackHTML = """
<!DOCTYPE html>
<html>
<head>
  <style id="esc-plain-text-styles">
    .esc-plain-main { white-space: pre-wrap; }
  </style>
</head>
<body>
  <div class="esc-plain-main">American Museum of Natural History</div>
  <details class="esc-plain-details">
    <summary>See More</summary>
    <div class="esc-plain-quotes">Tracked links and collapsed plain text</div>
  </details>
</body>
</html>
"""

private let degradedTransactionalPlainText = """
City National Bank / Zelle payment alert

Andrew Archer sent you $100.00.
Date
Apr 8, 2026
Status
Completed

Review this payment in your banking app:
https://example.com/open
"""

private let degradedTransactionalHTML = """
<!DOCTYPE html>
<html>
<head>
  <style>
    .actionButton table { display: none; }
    body { margin: 0; padding: 0; background: #ffffff; }
    table { border-collapse: collapse; }
  </style>
</head>
<body>
  <table width="100%"><tr><td align="center"><img src="https://example.com/logo.png" alt="City National Bank" width="180"></td></tr></table>
  <table width="100%"><tr><td height="72">&nbsp;</td></tr></table>
  <table width="100%"><tr><td height="96">&nbsp;</td></tr></table>
  <table width="100%"><tr><td align="center"><img src="https://example.com/zelle.png" alt="Zelle" width="110"></td></tr></table>
  <table width="100%"><tr><td style="font-size:14px; line-height:22px;">A payment notification is available in your secure inbox.</td></tr></table>
  <table class="actionButton" width="100%"><tr><td><a href="https://example.com/open">View Payment</a></td></tr></table>
  <table width="100%"><tr><td height="84">&nbsp;</td></tr></table>
  <table width="100%"><tr><td style="font-size:11px; line-height:18px; color:#666666;">Privacy Policy | Security Center | Do not reply to this email.</td></tr></table>
</body>
</html>
"""

private let hiddenCTAPlainText = """
Example Bank security alert

Verify your login to continue.
Use this verification code: 482913
https://example.com/verify
"""

private let hiddenCTAHTML = """
<!DOCTYPE html>
<html>
<head>
  <style>
    .primaryCTA { display: none; }
  </style>
</head>
<body>
  <table width="100%"><tr><td align="center"><img src="https://example.com/logo.png" alt="Example Bank" width="180"></td></tr></table>
  <table width="100%"><tr><td height="64">&nbsp;</td></tr></table>
  <table width="100%"><tr><td>Please verify your login in the mobile app.</td></tr></table>
  <table class="primaryCTA" width="100%"><tr><td><a href="https://example.com/verify">Verify now</a></td></tr></table>
  <table width="100%"><tr><td style="font-size:11px; color:#666666;">Security Center | Privacy Policy</td></tr></table>
</body>
</html>
"""

private let duplicatedPlainTextTransactionalRawSource = """
Delivered-To: person@example.com
Received: by 2002:a05:6e04:108f:b0:3ac:63b9:5e27 with SMTP id u15csp476934imc;
X-Received: by 2002:a05:7022:6899:b0:123:35c4:f39c with SMTP id a92af1059eb24;
Return-Path: <alerts@cnb.com>
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="dup-boundary-123"

--dup-boundary-123
Content-Type: text/plain; charset="UTF-8"

City National Bank / Zelle payment alert

Andrew Archer sent you $100.00.
Date
Apr 8, 2026
Status
Completed

Review this payment in your banking app:
https://example.com/open

--dup-boundary-123
Content-Type: text/plain; charset="UTF-8"

City National Bank / Zelle payment alert

Andrew Archer sent you $100.00.
Date
Apr 8, 2026
Status
Completed

Review this payment in your banking app:
https://example.com/open

--dup-boundary-123
Content-Type: text/html; charset="UTF-8"

<!DOCTYPE html>
<html>
<head>
  <style>
    .actionButton table { display: none; }
  </style>
</head>
<body>
  <table width="100%"><tr><td align="center"><img src="https://example.com/logo.png" alt="City National Bank" width="180"></td></tr></table>
  <table width="100%"><tr><td height="72">&nbsp;</td></tr></table>
  <table width="100%"><tr><td height="96">&nbsp;</td></tr></table>
  <table width="100%"><tr><td>A payment notification is available in your secure inbox.</td></tr></table>
  <table class="actionButton" width="100%"><tr><td><a href="https://example.com/open">View Payment</a></td></tr></table>
  <table width="100%"><tr><td style="font-size:11px; color:#666666;">Privacy Policy | Security Center | Do not reply to this email.</td></tr></table>
</body>
</html>

--dup-boundary-123--
"""
