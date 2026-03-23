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
        XCTAssertFalse((result.html ?? "").contains("src=\"data:image/png;base64,"))

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
               html.contains("src=\"data:image/png;base64,") {
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
