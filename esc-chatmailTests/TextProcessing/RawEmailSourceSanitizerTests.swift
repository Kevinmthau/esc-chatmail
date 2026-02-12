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
}
