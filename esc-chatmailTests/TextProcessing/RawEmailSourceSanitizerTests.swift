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
}
