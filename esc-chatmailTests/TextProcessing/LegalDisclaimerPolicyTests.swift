import XCTest
@testable import esc_chatmail

/// Pins `LegalDisclaimerPolicy`, the classifier behind the trailing-disclaimer passes of
/// `EmailDOMQuoteRemover` and `PlainTextSignatureRemover`. The golden corpus pins what the
/// bubble shows; this pins the rule's edges. Mirrored by `web/src/mime/legalDisclaimer.test.ts`.
final class LegalDisclaimerPolicyTests: XCTestCase {
    /// The Front transport footer that leaked (2026-11-17), with the company renamed.
    private let addresseeDisclaimer = "This communication is the property of Northwind and its affiliates; " +
        "it is confidential and intended solely for the use of the addressee(s). We expressly disclaim any " +
        "reliance on or use of this communication by anyone else. If you are not an addressee, please notify " +
        "the sender and delete this message immediately from your computer, computing device, and/or all " +
        "related systems and data storage."

    // Revert-check: LegalDisclaimerPolicy.clausePatterns .misdirectedReader "an? … addressee".
    func testClauses_addresseeWording_namesEveryKindOfClause() {
        XCTAssertEqual(
            LegalDisclaimerPolicy.clauses(in: addresseeDisclaimer),
            [.misdirectedReader, .confidentiality, .intendedReader, .notifySender, .deleteMessage, .prohibition]
        )
        XCTAssertTrue(LegalDisclaimerPolicy.isDisclaimer(addresseeDisclaimer))
    }

    func testClauses_receivedInErrorWording_isMisdirectedReader() {
        for text in [
            "If you have received this e-mail in error, please delete it.",
            "If you believe you received this message by mistake, tell us.",
            "If you aren’t the intended recipient, stop reading."
        ] {
            XCTAssertTrue(LegalDisclaimerPolicy.clauses(in: text).contains(.misdirectedReader), text)
        }
    }

    // Revert-check: the `.misdirectedReader || .intendedReader` guard in isDisclaimer.
    func testIsDisclaimer_threeClausesWithNoReader_isNotADisclaimer() {
        let text = "This confidential plan must not be forwarded; unauthorized copies are prohibited, so delete the attachments."
        XCTAssertEqual(LegalDisclaimerPolicy.clauses(in: text), [.confidentiality, .prohibition, .deleteMessage])
        XCTAssertFalse(LegalDisclaimerPolicy.isDisclaimer(text))
    }

    // Revert-check: the `found.count >= 3` floor in isDisclaimer.
    func testIsDisclaimer_existingOneLineFooters_needMoreThanTwoClauses() {
        for text in [
            "CONFIDENTIALITY NOTICE: This e-mail and any attachments are for the exclusive use of the intended recipient.",
            "Confidentiality notice: remove the intended recipient clause and the word confidential.",
            "This email may contain confidential information. Please forward it to counsel."
        ] {
            XCTAssertFalse(LegalDisclaimerPolicy.isDisclaimer(text), text)
        }
    }

    func testTrailingDisclaimerStartLine_disclaimerAfterSignOff_startsAtTheDisclaimer() {
        let lines = ["Please find the summary attached.", "", "Thanks", "Robin", "", addresseeDisclaimer]
        XCTAssertEqual(LegalDisclaimerPolicy.trailingDisclaimerStartLine(in: lines), 5)
    }

    // Revert-check: ParagraphEvidence.belongsToDisclaimer's two-clause floor.
    func testTrailingDisclaimerStartLine_authoredOneClauseLineBefore_staysOutOfTheDisclaimer() {
        let lines = ["Here is the draft.", "Please keep this confidential.", addresseeDisclaimer]
        XCTAssertEqual(LegalDisclaimerPolicy.trailingDisclaimerStartLine(in: lines), 2)
    }

    func testTrailingDisclaimerStartLine_headingAndEnvironmentFooter_belongToTheDisclaimer() {
        let lines = [
            "Reply.", "", "CONFIDENTIALITY NOTICE:", addresseeDisclaimer, "",
            "Please consider the environment before printing this e-mail."
        ]
        XCTAssertEqual(LegalDisclaimerPolicy.trailingDisclaimerStartLine(in: lines), 2)
    }

    // Revert-check: ParagraphEvidence.isPostscript.
    func testTrailingDisclaimerStartLine_postscriptAfter_isNil() {
        let lines = ["Here is the draft.", "", addresseeDisclaimer, "", "P.S. The confidential copy is attached."]
        XCTAssertNil(LegalDisclaimerPolicy.trailingDisclaimerStartLine(in: lines))
    }

    // Revert-check: the `runStart > 1` bound in trailingDisclaimerStartLine.
    func testTrailingDisclaimerStartLine_disclaimerAlone_isNil() {
        XCTAssertNil(LegalDisclaimerPolicy.trailingDisclaimerStartLine(in: [addresseeDisclaimer]))
        XCTAssertNil(LegalDisclaimerPolicy.trailingDisclaimerStartLine(in: ["", addresseeDisclaimer, ""]))
    }

    // Revert-check: LegalDisclaimerPolicy.continuesParagraph.
    func testTrailingDisclaimerStartLine_hardWrappedDisclaimer_startsAtItsFirstLine() {
        let lines = [
            "Thanks,", "Robin", "",
            "This communication is the property of Northwind and its affiliates; it is",
            "confidential and intended solely for the use of the addressee(s). If you",
            "are not an addressee, please notify the sender and delete this message."
        ]
        XCTAssertEqual(LegalDisclaimerPolicy.trailingDisclaimerStartLine(in: lines), 3)
    }

    /// A capitalized line after one that ends no sentence starts a paragraph, so a
    /// sign-off and name above a disclaimer with no blank line between stay.
    func testTrailingDisclaimerStartLine_signOffWithNoBlankLine_staysOutOfTheDisclaimer() {
        let lines = ["Please find the summary attached.", "Thanks", "Robin", addresseeDisclaimer]
        XCTAssertEqual(LegalDisclaimerPolicy.trailingDisclaimerStartLine(in: lines), 3)
    }

    func testTrailingDisclaimerStartLine_noClauseParagraphLast_isNil() {
        let lines = ["Reply.", "", addresseeDisclaimer, "", "Email cannot be guaranteed to be secure or error-free."]
        XCTAssertNil(LegalDisclaimerPolicy.trailingDisclaimerStartLine(in: lines))
    }
}
