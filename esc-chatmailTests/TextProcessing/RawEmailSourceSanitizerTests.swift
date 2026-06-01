import XCTest
@testable import esc_chatmail

final class RawEmailSourceSanitizerTests: XCTestCase {
    func testExtractDisplayText_rawMultipartSource_extractsPlainTextBody() {
        let extracted = RawEmailSourceSanitizer.extractDisplayText(from: rawMultipartEmail)

        XCTAssertTrue(extracted.contains("Hello again, Kevin -"))
        XCTAssertTrue(extracted.contains("Please let us know your preference."))
        XCTAssertFalse(extracted.contains("Delivered-To:"))
        XCTAssertFalse(extracted.contains("Content-Type: multipart"))
        XCTAssertFalse(extracted.contains("--000000000000da2939"))
    }

    func testPipeline_rawMultipartSource_removesQuotedHistoryAndSignature() {
        let extracted = RawEmailSourceSanitizer.extractDisplayText(from: rawMultipartEmail)
        let unwrapped = TextProcessing.unwrapEmailLineBreaks(from: extracted)
        let cleaned = PlainTextQuoteRemover.removeQuotes(from: unwrapped) ?? ""

        XCTAssertTrue(cleaned.contains("Hello again, Kevin -"))
        XCTAssertTrue(cleaned.contains("Please let us know your preference."))
        XCTAssertFalse(cleaned.contains("On Wed, Feb 11, 2026"))
        XCTAssertFalse(cleaned.contains("Warm regards"))
        XCTAssertFalse(cleaned.contains("617.221.4242"))
    }

    func testExtractDisplayText_normalMessage_returnsUnchanged() {
        let text = """
        Hi Kevin,

        Can we confirm this tomorrow?

        Thanks,
        Barbara
        """

        let extracted = RawEmailSourceSanitizer.extractDisplayText(from: text)
        XCTAssertEqual(extracted, text)
    }

    func testExtractDisplayText_nestedMultipartBoundaries_doNotBleedIntoPlainPart() {
        let extracted = RawEmailSourceSanitizer.extractDisplayText(from: nestedRawMultipartEmail)

        XCTAssertEqual(
            extracted,
            """
            Hi Brynn and Kevin,

            We are delighted to invite you to opening night.
            Please let me know if you'll be able to make it.
            """
        )
        XCTAssertFalse(extracted.contains("<html"))
        XCTAssertFalse(extracted.contains("Content-Type: text/html"))
        XCTAssertFalse(extracted.contains("iVBORw0KGgo"))
    }

    func testExtractDisplayText_boundaryLikeBodyLine_isPreserved() {
        let extracted = RawEmailSourceSanitizer.extractDisplayText(from: rawMultipartEmailWithBoundaryLikeBodyLine)

        XCTAssertEqual(
            extracted,
            """
            Hi team,

            Please keep this separator in the body:
            --1234567890ABCDEF1234567890
            This line should remain visible.
            """
        )
    }

    func testExtractDisplayText_repeatedSignatureSeparator_isNotInferredAsBoundary() {
        let extracted = RawEmailSourceSanitizer.extractDisplayText(from: rawMultipartEmailWithRepeatedSignatureSeparator)

        XCTAssertEqual(
            extracted,
            """
            Hi Kevin,

            We can do Tuesday.

            --Thanks,
            Barbara

            P.S. Repeating the sign-off should stay in the body.
            --Thanks,
            Barbara
            """
        )
    }

    func testExtractHTMLText_newsletterRawSource_extractsHTMLBody() {
        let extracted = RawEmailSourceSanitizer.extractHTMLText(from: rawNewsletterMultipartEmail)

        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted?.contains("Tickets are now on sale for the Spring Documentary Festival") == true)
        XCTAssertTrue(extracted?.contains("Unsubscribe") == true)
        XCTAssertFalse(extracted?.contains("Delivered-To:") == true)
        XCTAssertFalse(extracted?.contains("Content-Type: text/plain") == true)
    }

    func testExtractHTMLText_klaviyoStyleRawSource_extractsDecodedHTMLBody() {
        let extracted = RawEmailSourceSanitizer.extractHTMLText(from: klaviyoStyleRawNewsletterEmail)

        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted?.contains("Roma Heirloom Tomato Candle") == true)
        XCTAssertTrue(extracted?.contains("Flamingo Estate") == true)
        XCTAssertTrue(extracted?.contains("https://cdn.shopify.com/s/files/1/0000/products/tomato-candle.png?v=1712345678") == true)
        XCTAssertTrue(extracted?.contains("https://d3k81ch9hvuctc.cloudfront.net/company/flamingo/header.gif") == true)
        XCTAssertFalse(extracted?.contains("Content-Type: text/plain") == true)
        XCTAssertFalse(extracted?.contains("Content-Transfer-Encoding: quoted-printable") == true)
        XCTAssertFalse(extracted?.contains("===============728914537882421==") == true)
        XCTAssertFalse(extracted?.contains("Plain fallback should not appear") == true)
    }

    func testExtractDisplayText_rawMultipartSource_withQuestionMarkBoundary_extractsPlainTextBody() {
        let extracted = RawEmailSourceSanitizer.extractDisplayText(from: rawMultipartEmailWithQuestionMarkBoundary)

        XCTAssertTrue(extracted.contains("MRH"))
        XCTAssertTrue(extracted.contains("https://example.com/plain"))
        XCTAssertFalse(extracted.contains("HTML_TOKEN_BOUNDARY_QUESTION_MARK"))
        XCTAssertFalse(extracted.contains("Content-Type: text/html"))
    }

    func testExtractHTMLText_rawMultipartSource_withQuestionMarkBoundary_extractsHTMLBody() {
        let extracted = RawEmailSourceSanitizer.extractHTMLText(from: rawMultipartEmailWithQuestionMarkBoundary)

        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted?.contains("HTML_TOKEN_BOUNDARY_QUESTION_MARK") == true)
        XCTAssertTrue(extracted?.contains("Nescens Retreats") == true)
        XCTAssertFalse(extracted?.contains("Content-Type: text/plain") == true)
    }

    func testExtractDisplayText_mimeOnlyMultipartSource_extractsPlainTextBody() {
        let extracted = RawEmailSourceSanitizer.extractDisplayText(from: mimeOnlyRawMultipartEmail)

        XCTAssertTrue(extracted.contains("Example Museum"))
        XCTAssertTrue(extracted.contains("Tickets are now on sale for the 2026 Film Festival"))
        XCTAssertFalse(extracted.contains("Content-Type: multipart"))
        XCTAssertFalse(extracted.contains("--newsletter-boundary-123"))
    }

    func testExtractHTMLText_mimeOnlyMultipartSource_extractsHTMLBody() {
        let extracted = RawEmailSourceSanitizer.extractHTMLText(from: mimeOnlyRawMultipartEmail)

        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted?.contains("HTML_TOKEN_MIME_ONLY") == true)
        XCTAssertTrue(extracted?.contains("Learn More") == true)
        XCTAssertFalse(extracted?.contains("Content-Type: text/plain") == true)
    }

    private var rawMultipartEmail: String {
        """
        Delivered-To: kmthau@gmail.com
        Received: by 2002:a05:6e04:71a:b0:3ac:63b9:5e27 with SMTP id o26csp460566imz;
                Wed, 11 Feb 2026 13:19:21 -0800 (PST)
        Return-Path: <barbara@travellustre.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="000000000000da2939"

        --000000000000da2939
        Content-Type: multipart/alternative; boundary="000000000000da2937"

        --000000000000da2937
        Content-Type: text/plain; charset="UTF-8"
        Content-Transfer-Encoding: quoted-printable

        Hello again, Kevin -=0A=
        Attached are the accommodation options.=0A=0A=
        Please let us know your preference.=0A=0A=
        On Wed, Feb 11, 2026 at 3:36 PM Barbara Merrigan <barbara@travellustre.com> wrote:=0A=
        > Here is the flight proposal for Agnes and the nanny.=0A=
        -- =0A=0A=
        Warm regards,=0A=0A=
        Barbara Merrigan=0A=
        P: 617.221.4242 x112

        --000000000000da2937
        Content-Type: text/html; charset="UTF-8"

        <div dir="ltr">Hello again, Kevin -</div>
        --000000000000da2937--
        --000000000000da2939
        Content-Type: application/pdf; name="Bulgari Roma Accommodation Proposal.pdf"
        Content-Disposition: attachment; filename="Bulgari Roma Accommodation Proposal.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjcK
        --000000000000da2939--
        """
    }

    private var nestedRawMultipartEmail: String {
        """
        Delivered-To: kmthau@gmail.com
        Received: by 2002:a05:6e04:108f:b0:3ac:63b9:5e27 with SMTP id u15csp476934imc;
                Tue, 24 Feb 2026 14:02:53 -0800 (PST)
        X-Received: by 2002:a05:7022:6899:b0:123:35c4:f39c with SMTP id a92af1059eb24;
                Tue, 24 Feb 2026 14:02:53 -0800 (PST)
        Return-Path: <sender@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="_006_outer_boundary"

        --_006_outer_boundary
        Content-Type: multipart/related; boundary="_005_related_boundary"; type="multipart/alternative"

        --_005_related_boundary
        Content-Type: multipart/alternative; boundary="_000_alternative_boundary"

        --_000_alternative_boundary
        Content-Type: text/plain; charset="Windows-1252"
        Content-Transfer-Encoding: quoted-printable

        Hi Brynn and Kevin,

        We are delighted to invite you to opening night.
        Please let me know if you=27ll be able to make it.

        --_000_alternative_boundary
        Content-Type: text/html; charset="Windows-1252"
        Content-Transfer-Encoding: quoted-printable

        <html><body><div>Hi Brynn and Kevin,</div></body></html>

        --_000_alternative_boundary--
        --_005_related_boundary
        Content-Type: image/png; name="image001.png"
        Content-Disposition: inline; filename="image001.png"
        Content-ID: <image001.png@01DCA5AF.35846080>
        Content-Transfer-Encoding: base64

        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2foAAAAASUVORK5CYII=

        --_005_related_boundary--
        --_006_outer_boundary
        Content-Type: image/png; name="invite.png"
        Content-Disposition: attachment; filename="invite.png"
        Content-Transfer-Encoding: base64

        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2foAAAAASUVORK5CYII=

        --_006_outer_boundary--
        """
    }

    private var rawMultipartEmailWithBoundaryLikeBodyLine: String {
        """
        Delivered-To: kmthau@gmail.com
        Received: by 2002:a05:6e04:108f:b0:3ac:63b9:5e27 with SMTP id u15csp476934imc;
                Tue, 24 Feb 2026 14:02:53 -0800 (PST)
        X-Received: by 2002:a05:7022:6899:b0:123:35c4:f39c with SMTP id a92af1059eb24;
                Tue, 24 Feb 2026 14:02:53 -0800 (PST)
        Return-Path: <sender@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="mixed-boundary-12345"

        --mixed-boundary-12345
        Content-Type: text/plain; charset="UTF-8"
        Content-Transfer-Encoding: quoted-printable

        Hi team,

        Please keep this separator in the body:
        --1234567890ABCDEF1234567890
        This line should remain visible.

        --mixed-boundary-12345
        Content-Type: text/html; charset="UTF-8"

        <html><body><div>Hi team</div></body></html>

        --mixed-boundary-12345--
        """
    }

    private var rawMultipartEmailWithRepeatedSignatureSeparator: String {
        """
        Delivered-To: kmthau@gmail.com
        Received: by 2002:a05:6e04:108f:b0:3ac:63b9:5e27 with SMTP id u15csp476934imc;
                Tue, 24 Feb 2026 14:02:53 -0800 (PST)
        X-Received: by 2002:a05:7022:6899:b0:123:35c4:f39c with SMTP id a92af1059eb24;
                Tue, 24 Feb 2026 14:02:53 -0800 (PST)
        Return-Path: <sender@example.com>
        MIME-Version: 1.0
        Subject: Schedule
        Content-Type: multipart/alternative; boundary="fallback-boundary-12345"

        --fallback-boundary-12345
        Content-Type: text/plain; charset="UTF-8"
        Content-Transfer-Encoding: 8bit

        Hi Kevin,

        We can do Tuesday.

        --Thanks,
        Barbara

        P.S. Repeating the sign-off should stay in the body.
        --Thanks,
        Barbara

        --fallback-boundary-12345
        Content-Type: text/html; charset="UTF-8"
        Content-Transfer-Encoding: 8bit

        <html><body><div>Hi Kevin</div></body></html>

        --fallback-boundary-12345--
        """
    }

    private var rawNewsletterMultipartEmail: String {
        """
        Delivered-To: person@example.com
        Received: by 2002:a05:6e04:71a:b0:3ac:63b9:5e27 with SMTP id o26csp2106356imz;
                Tue, 7 Apr 2026 12:33:01 -0700 (PDT)
        X-Received: by 2002:ac8:7dd4:0:b0:503:4257:da03 with SMTP id d75a77;
                Tue, 7 Apr 2026 12:33:00 -0700 (PDT)
        Return-Path: <newsletter@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="newsletter-boundary-123"

        --newsletter-boundary-123
        Content-Type: text/plain; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable

        Example Museum
        https://example.com/logo

        View in Browser
        https://example.com/view

        Tickets are now on sale for the Spring Documentary Festival
        Join us for a showcase of outstanding documentary films.

        Learn More
        https://example.com/learn-more

        Unsubscribe
        https://example.com/unsubscribe

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
    }

    private var klaviyoStyleRawNewsletterEmail: String {
        """
        Delivered-To: person@example.com
        Received: by 2002:a05:6e04:71a:b0:3ac:63b9:5e27 with SMTP id o26csp2106356imz;
                Mon, 18 May 2026 09:12:31 -0700 (PDT)
        X-Received: by 2002:a05:6214:4f02:b0:8ae:652b:e3c4 with SMTP id 6a1803df08f44;
                Mon, 18 May 2026 09:12:31 -0700 (PDT)
        Return-Path: <bounce-12345@email.flamingoestate.example>
        MIME-Version: 1.0
        Subject: A bright note from Flamingo Estate
        Content-Type: multipart/alternative; boundary="===============728914537882421=="

        --===============728914537882421==
        Content-Type: text/plain; charset="UTF-8"
        Content-Transfer-Encoding: quoted-printable

        Plain fallback should not appear in extracted HTML.
        Roma Heirloom Tomato Candle
        https://example.com/products/tomato-candle

        --===============728914537882421==
        Content-Transfer-Encoding: quoted-printable
        Content-Type: text/html; charset="UTF-8"

        <!doctype html>
        <html>
        <body>
          <div style=3D"display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">
            A bright note from Flamingo Estate &zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;
          </div>
          <table role=3D"presentation" width=3D"100%">
            <tr>
              <td>
                <img src=3D"https://d3k81ch9hvuctc.cloudfront.net/company/flamingo/header.gif" alt=3D"Flamingo Estate">
              </td>
            </tr>
            <tr>
              <td>
                <img src=3D"https://cdn.shopify.com/s/files/1/0000/products/tomato-candle.png?v=3D1712345678" alt=3D"Roma Heirloom Tomato Candle">
                <h1>Roma Heirloom Tomato Candle</h1>
                <p>Sun-warmed leaves, garden vines, and a green finish.</p>
              </td>
            </tr>
            <tr>
              <td>
                <img src=3D"https://cdn.shopify.com/s/files/1/0000/products/tomato-candle-detail.png?v=3D1712345678" alt=3D"Tomato candle detail">
                <a href=3D"https://example.com/products/tomato-candle">Shop now</a>
              </td>
            </tr>
          </table>
        </body>
        </html>

        --===============728914537882421==--
        """
    }

    private var rawMultipartEmailWithQuestionMarkBoundary: String {
        """
        Delivered-To: person@example.com
        Received: by 2002:ac0:e350:0:b0:3bc:5c5b:71d2 with SMTP id g16csp909309imn;
                Sat, 18 Apr 2026 16:01:33 -0700 (PDT)
        X-Received: by 2002:a05:6214:4f02:b0:8ae:652b:e3c4 with SMTP id 6a1803df08f44;
                Sat, 18 Apr 2026 16:01:33 -0700 (PDT)
        Return-Path: <bounce@example.com>
        MIME-Version: 1.0
        Subject: Nescens Retreats
        Content-Type: multipart/alternative; boundary="vnPiSyJVkpSc=_?:"

        --vnPiSyJVkpSc=_?:
        Content-Type: text/plain; charset="utf-8"
        Content-Transfer-Encoding: 8bit

        MRH
        https://example.com/plain

        --vnPiSyJVkpSc=_?:
        Content-Type: text/html; charset="utf-8"
        Content-Transfer-Encoding: 8bit

        <!DOCTYPE html>
        <html>
        <body>
          <h1>HTML_TOKEN_BOUNDARY_QUESTION_MARK</h1>
          <p>Nescens Retreats</p>
        </body>
        </html>

        --vnPiSyJVkpSc=_?:--
        """
    }

    private var mimeOnlyRawMultipartEmail: String {
        """
        Content-Type: multipart/alternative; boundary="newsletter-boundary-123"
        MIME-Version: 1.0

        --newsletter-boundary-123
        Content-Type: text/plain; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable

        Example Museum
        Tickets are now on sale for the 2026 Film Festival
        View in Browser
        Learn More

        --newsletter-boundary-123
        Content-Type: text/html; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable

        <!DOCTYPE html>
        <html>
        <body>
          <h1>HTML_TOKEN_MIME_ONLY</h1>
          <p>Tickets are now on sale for the 2026 Film Festival</p>
          <p><a href=3D"https://example.com/learn-more">Learn More</a></p>
        </body>
        </html>

        --newsletter-boundary-123--
        """
    }
}
