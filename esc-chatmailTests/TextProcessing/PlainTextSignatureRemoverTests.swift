import XCTest
@testable import esc_chatmail

/// CX2 characterization: pins PlainTextSignatureRemover's current
/// signature-detection behavior before its pattern definitions move to
/// shared TextPatterns namespaces. Previously covered only indirectly via
/// ProcessedTextCacheTests.
final class PlainTextSignatureRemoverTests: XCTestCase {

    // MARK: - Degenerate inputs

    func testEmptyInput_returnsEmpty() {
        XCTAssertEqual(PlainTextSignatureRemover.removeSignature(from: ""), "")
    }

    func testWhitespaceOnlyInput_returnsEmpty() {
        XCTAssertEqual(PlainTextSignatureRemover.removeSignature(from: "  \n\t \n"), "")
    }

    func testSingleLineInput_isReturnedTrimmedEvenIfSignatureLike() {
        // The remover requires multiple lines before it will classify anything.
        XCTAssertEqual(
            PlainTextSignatureRemover.removeSignature(from: "Sent from my iPhone"),
            "Sent from my iPhone"
        )
    }

    // MARK: - Hard indicators

    func testMobileFooter_isRemoved() {
        let text = """
        See you at the meeting tomorrow.

        Sent from my iPhone
        """
        XCTAssertEqual(
            PlainTextSignatureRemover.removeSignature(from: text),
            "See you at the meeting tomorrow."
        )
    }

    func testCRLFInput_isNormalizedBeforeDetection() {
        let text = "See you at the meeting tomorrow.\r\n\r\nSent from my iPhone"
        let result = PlainTextSignatureRemover.removeSignature(from: text)
        XCTAssertEqual(result, "See you at the meeting tomorrow.")
        XCTAssertFalse(result.contains("\r"))
    }

    func testDelimiterSignature_isCutAtDelimiter() {
        let text = """
        Lunch is confirmed for noon.

        --
        Jane Smith
        415-555-0100
        """
        XCTAssertEqual(
            PlainTextSignatureRemover.removeSignature(from: text),
            "Lunch is confirmed for noon."
        )
    }

    func testUnsubscribeFooter_isRemoved() {
        let text = """
        Your weekly digest is ready to read.

        Unsubscribe from these notifications at any time.
        """
        XCTAssertEqual(
            PlainTextSignatureRemover.removeSignature(from: text),
            "Your weekly digest is ready to read."
        )
    }

    func testLegalDisclaimer_isRemoved() {
        let text = """
        The contract is attached for your review.

        This email and any attachments are confidential and intended solely
        for the use of the individual to whom they are addressed.
        """
        XCTAssertEqual(
            PlainTextSignatureRemover.removeSignature(from: text),
            "The contract is attached for your review."
        )
    }

    func testTrailingInlineImagePlaceholder_isRemoved() {
        let text = """
        Here is the updated logo for the site.

        [cid:image001.png@01DA1234.ABCD5678]
        """
        XCTAssertEqual(
            PlainTextSignatureRemover.removeSignature(from: text),
            "Here is the updated logo for the site."
        )
    }

    // MARK: - Heuristic contact blocks

    func testSignOffContactBlock_isRemoved() {
        let text = """
        Hi team,

        The quarterly numbers look great, nice work everyone.

        Thanks,
        John Smith
        Acme Corp | Sales Director
        john.smith@acme.com
        415-555-0123
        """
        let result = PlainTextSignatureRemover.removeSignature(from: text)
        XCTAssertTrue(result.contains("The quarterly numbers look great"), "Unexpected result: \(result)")
        XCTAssertFalse(result.contains("john.smith@acme.com"), "Unexpected result: \(result)")
        XCTAssertFalse(result.contains("415-555-0123"), "Unexpected result: \(result)")
        XCTAssertFalse(result.contains("Sales Director"), "Unexpected result: \(result)")
    }

    func testPhoneNumberInProse_isPreserved() {
        let text = """
        Hi Sarah,

        Feel free to call me at 415-314-9804 whenever works for you.

        We can go over the details then.
        """
        let result = PlainTextSignatureRemover.removeSignature(from: text)
        XCTAssertTrue(result.contains("415-314-9804"), "Unexpected result: \(result)")
        XCTAssertTrue(result.contains("We can go over the details then."), "Unexpected result: \(result)")
    }

    func testShortSignOffOnlyMessage_isPreserved() {
        // Short messages without contact info are left alone.
        let text = """
        Sounds good!

        Best,
        Kevin
        """
        XCTAssertEqual(PlainTextSignatureRemover.removeSignature(from: text), text)
    }

    func testPostscriptAfterSignOff_isPreserved() {
        let text = """
        The garden party is still on for Saturday.

        Thanks,
        Maria

        P.S. Bring sunscreen this time.
        """
        XCTAssertEqual(PlainTextSignatureRemover.removeSignature(from: text), text)
    }

    func testContactListIntro_preservesListedEmails() {
        // An intro line ending in ":" marks the emails as body content, not signature.
        let text = """
        Here are the reviewer contacts:

        anna@example.com
        bruno@example.com
        """
        let result = PlainTextSignatureRemover.removeSignature(from: text)
        XCTAssertTrue(result.contains("anna@example.com"), "Unexpected result: \(result)")
        XCTAssertTrue(result.contains("bruno@example.com"), "Unexpected result: \(result)")
    }

    func testWireFraudWarning_isRemoved() {
        let text = """
        Escrow documents are ready for your signature.

        WIRE FRAUD IS REAL. Before wiring any money, call the intended
        recipient at a number you know is valid to confirm the instructions.
        """
        XCTAssertEqual(
            PlainTextSignatureRemover.removeSignature(from: text),
            "Escrow documents are ready for your signature."
        )
    }

    func testAddressBlockSignature_isRemoved() {
        let text = """
        I'll have the paperwork ready before Friday.

        Regards,
        Dana Lee
        Lee Realty Group
        200 Main Street, Suite 340
        dana@leerealty.com
        """
        let result = PlainTextSignatureRemover.removeSignature(from: text)
        XCTAssertTrue(result.contains("I'll have the paperwork ready before Friday."), "Unexpected result: \(result)")
        XCTAssertFalse(result.contains("200 Main Street"), "Unexpected result: \(result)")
        XCTAssertFalse(result.contains("dana@leerealty.com"), "Unexpected result: \(result)")
    }

    func testBodyOnlyMessage_isUnchanged() {
        let text = """
        The deployment finished without errors.

        All the dashboards look healthy, and latency is back to normal.

        We should be clear to close the incident.
        """
        XCTAssertEqual(PlainTextSignatureRemover.removeSignature(from: text), text)
    }
}
