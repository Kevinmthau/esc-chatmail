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
}
