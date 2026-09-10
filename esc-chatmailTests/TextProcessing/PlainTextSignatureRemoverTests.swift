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

    // Revert-check: PlainTextSignatureRemover contact-prefix, anchored-tail and
    // sign-off policy / web signature.ts. Both removal and preservation are pinned.
    // HONEST SCOPE: mobile/legal/wire cases are existing removal controls.
    func testAuditedPlainTextSignaturesAndBodyTails() {
        let cases: [(String, String, String)] = [
            ("title_prose", "Please review the plan.\n\nCONFIDENTIALITY NOTICE: This email is confidential.\n\nThe manager will call tomorrow.", "Please review the plan.\n\nCONFIDENTIALITY NOTICE: This email is confidential.\n\nThe manager will call tomorrow."),
            ("email_prose", "Please review the plan.\n\nCONFIDENTIALITY NOTICE: This email is confidential.\n\nPlease send the revised plan to bob@example.com.", "Please review the plan.\n\nCONFIDENTIALITY NOTICE: This email is confidential.\n\nPlease send the revised plan to bob@example.com."),
            ("url_prose", "Please review the plan.\n\nCONFIDENTIALITY NOTICE: This email is confidential.\n\nPlease review the revised plan at https://example.com/plan.", "Please review the plan.\n\nCONFIDENTIALITY NOTICE: This email is confidential.\n\nPlease review the revised plan at https://example.com/plan."),
            ("authored_tagline_body_sentence", "Please review the plan.\n\nThe homeowner will coordinate with the broker.\nThe estimate changed.\n415-555-1212\njane@example.com", "Please review the plan.\n\nThe homeowner will coordinate with the broker.\nThe estimate changed.\n415-555-1212\njane@example.com"),
            ("authored_tagline_personal_name", "Please review the plan.\n\nJane Doe\nThe estimate changed.\n415-555-1212\njane@example.com", "Please review the plan.\n\nJane Doe\nThe estimate changed.\n415-555-1212\njane@example.com"),
            ("body_before_legal_footer", "The manager will call tomorrow.\n\nThis email and any attachments are confidential.", "The manager will call tomorrow."),

            ("legal_words_in_body", "Confidentiality notice: we need to discuss this.\n\nThe account is ready for review.\n\nOur services launch on Monday.", "Confidentiality notice: we need to discuss this.\n\nThe account is ready for review.\n\nOur services launch on Monday."),
            ("body_after_legal_footer", "The document is attached.\n\nThis email and any attachments are confidential.\n\nThe account is ready and the terms are final.\n\nPlease review our services before Monday.", "The document is attached.\n\nThis email and any attachments are confidential.\n\nThe account is ready and the terms are final.\n\nPlease review our services before Monday."),
            ("titled_contact_list", "Here are the contacts:\n- Jane Doe — Account Manager — jane@example.com\n- John Roe — Sales Director — john@example.com\nhttps://example.com/team", "Here are the contacts:\n- Jane Doe — Account Manager — jane@example.com\n- John Roe — Sales Director — john@example.com\nhttps://example.com/team"),

            ("descriptive_phone_signature", "The repair is scheduled.\n\nBest,\nJohn Boga\nProperty Manager\nEmergency line after hours: 914-373-4658\nwww.nycbrownstone.net", "The repair is scheduled.\n\nBest,\nJohn Boga"),
            ("body_mobile-first", "Hi team,\n\nThe review is complete.\n\nMobile-first design is the priority for this release.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.", "Hi team,\n\nThe review is complete.\n\nMobile-first design is the priority for this release.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday."),
            ("body_m", "Hi team,\n\nThe review is complete.\n\nM. Smith will join us tomorrow.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.", "Hi team,\n\nThe review is complete.\n\nM. Smith will join us tomorrow.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday."),
            ("body_o-rings", "Hi team,\n\nThe review is complete.\n\nO-rings are back in stock.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.", "Hi team,\n\nThe review is complete.\n\nO-rings are back in stock.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday."),
            ("body_f-150", "Hi team,\n\nThe review is complete.\n\nF-150 is in the shop this week.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.", "Hi team,\n\nThe review is complete.\n\nF-150 is in the shop this week.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday."),
            ("body_d", "Hi team,\n\nThe review is complete.\n\nD. Wong signed off on the plan.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.", "Hi team,\n\nThe review is complete.\n\nD. Wong signed off on the plan.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday."),
            ("body_important", "Hi team,\n\nThe review is complete.\n\nImportant: the deadline moved to Monday.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.", "Hi team,\n\nThe review is complete.\n\nImportant: the deadline moved to Monday.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday."),
            ("body_you", "Hi team,\n\nThe review is complete.\n\nYou are receiving this because we need your input.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.", "Hi team,\n\nThe review is complete.\n\nYou are receiving this because we need your input.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday."),
            ("body_our", "Hi team,\n\nThe review is complete.\n\nOur privacy policy changed this week.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.", "Hi team,\n\nThe review is complete.\n\nOur privacy policy changed this week.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday."),
            ("orphan_postscript", "The delivery is confirmed.\n\nP.S. Please use the side entrance.", "The delivery is confirmed.\n\nP.S. Please use the side entrance."),
            ("long_reply_bare_signoff", "Hi team,\n\nThe review is complete.\n\nWe have updated the plan.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.\n\nBest,\nKevin", "Hi team,\n\nThe review is complete.\n\nWe have updated the plan.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.\n\nBest,\nKevin"),
            ("zoom_invite", "Topic: Weekly sync\nTime: September 12, 2026 10:00 AM\nJoin Zoom Meeting\nhttps://zoom.us/j/123456789\nMeeting ID: 123 456 789\nPasscode: 246810", "Topic: Weekly sync\nTime: September 12, 2026 10:00 AM\nJoin Zoom Meeting\nhttps://zoom.us/j/123456789\nMeeting ID: 123 456 789\nPasscode: 246810"),
            ("shipping_block", "Your order is on its way.\n\nShip to:\nJordan Smith\n123 Main Street\nNew York, NY 10013", "Your order is on its way.\n\nShip to:\nJordan Smith\n123 Main Street\nNew York, NY 10013"),
            ("calendar_block", "Design review\n\nWednesday, September 16, 2026\n10:00 AM - 11:00 AM\nLocation: Conference Room A", "Design review\n\nWednesday, September 16, 2026\n10:00 AM - 11:00 AM\nLocation: Conference Room A"),
            ("two_link_share", "Here are the links you asked for:\nhttps://example.com/one\nhttps://example.com/two", "Here are the links you asked for:\nhttps://example.com/one\nhttps://example.com/two"),
            ("contact_card_then_body", "Please reach out to our property manager directly:\nJohn Boga\nProperty Manager\njohn@example.com\n914-555-0123\n\nPlease copy me on your reply.", "Please reach out to our property manager directly:\nJohn Boga\nProperty Manager\njohn@example.com\n914-555-0123\n\nPlease copy me on your reply."),
            ("contact_list_followed_by_signoff", "If this matter is urgent, please contact:\n- Shane at shane@example.com or 424-555-0123\n- Victoria at victoria@example.com or 312-555-0123\n\nThank you,\nDominic", "If this matter is urgent, please contact:\n- Shane at shane@example.com or 424-555-0123\n- Victoria at victoria@example.com or 312-555-0123\n\nThank you,\nDominic"),
            ("footer_phrase_followed_by_body", "The draft is ready.\n\nUnsubscribe from these notifications.\n\nWe should keep that sentence in the new template.", "The draft is ready.\n\nUnsubscribe from these notifications.\n\nWe should keep that sentence in the new template."),
            ("signoff_contacts", "The contract is ready.\n\nSincerely,\nMarcita Threash\nSenior Account Manager\nProtecting what matters most.\nmarcita@example.com\n404-555-0142", "The contract is ready.\n\nSincerely,\nMarcita Threash"),
            ("mobile_footer", "The review is complete.\n\nSent from my iPhone", "The review is complete."),
            ("legal_footer", "The review is complete.\n\nThis email and any attachments are confidential and intended solely\nfor the use of the individual to whom they are addressed.", "The review is complete."),
            ("wire_fraud_footer", "Escrow documents are ready for your signature.\n\nWIRE FRAUD IS REAL. Before wiring any money, call the intended\nrecipient at a number you know is valid to confirm the instructions.", "Escrow documents are ready for your signature."),
        ]
        for (name, input, expected) in cases {
            XCTAssertEqual(PlainTextSignatureRemover.removeSignature(from: input), expected, name)
        }
    }

    func testFooterLikeAuthoredFinalParagraphs_arePreserved() {
        let paragraphs = [
            "This email may contain a mistake; please check the totals.",
            "This email may contain errors; please check the totals.",
            "This email may contain privileged attachments. Please forward them to counsel.",
            "This email may contain confidential information. Please forward it to counsel.",
            "Our Form CRS needs revision before we can send it.",
            "Update your preferences before the deadline.",
        ]

        for paragraph in paragraphs {
            let text = "Hi Kevin,\n\n\(paragraph)"
            XCTAssertEqual(PlainTextSignatureRemover.removeSignature(from: text), text, paragraph)
            let processed = ChatBubbleTextProcessor.process(
                content: text,
                options: ChatBubbleTextProcessorOptions(inputKind: .plainText)
            )
            XCTAssertEqual(processed.mainText, text, paragraph)
        }
    }

    func testEmergencyContactList_preservesHeadingAndAllNumbers() {
        for heading in [
            "Emergency Contacts", "Support Team", "Emergency Numbers", "Emergency Contact Numbers",
            "Support Numbers", "Escalation Matrix", "On-Call Roster", "Building Support"
        ] {
            let text = """
            Please keep these numbers handy.

            \(heading)
            Emergency line: 212-555-1234
            Customer service line: 212-555-5678
            """
            XCTAssertEqual(PlainTextSignatureRemover.removeSignature(from: text), text, heading)

            let processed = ChatBubbleTextProcessor.process(
                content: text,
                options: ChatBubbleTextProcessorOptions(inputKind: .plainText)
            )
            XCTAssertEqual(
                processed.mainText,
                "Please keep these numbers handy.\n\n\(heading)\n\nEmergency line: 212-555-1234\n\nCustomer service line: 212-555-5678",
                heading
            )
        }
    }

    func testKnownConfidentialityFooter_isStillRemoved() {
        for footer in [
            "This email may contain confidential or privileged information.",
            "This e-mail may contain confidential information intended only for the recipient.",
        ] {
            let text = "The contract is attached for your review.\n\n\(footer)"
            XCTAssertEqual(
                PlainTextSignatureRemover.removeSignature(from: text),
                "The contract is attached for your review.",
                footer
            )
        }
    }

    func testAuthoredSentenceBelowNameOrTitle_isNotConsumedAsTagline() {
        for heading in ["Jane Doe", "Senior Account Manager"] {
            for sentence in ["Budget has doubled.", "Do not send the contract."] {
                let text = "Please review the plan.\n\n\(heading)\n\(sentence)\n415-555-1212\nhttps://example.com/plan"
                let removed = PlainTextSignatureRemover.removeSignature(from: text)
                XCTAssertTrue(removed.contains(sentence), "Authored sentence lost: \(text)")
                let processed = ChatBubbleTextProcessor.process(
                    content: text,
                    options: ChatBubbleTextProcessorOptions(inputKind: .plainText)
                )
                XCTAssertTrue(processed.mainText?.contains(sentence) == true, "Authored sentence lost after processing: \(text)")
            }
        }
    }

    func testTitledLinkShare_preservesLinksThroughPlainTextProcessing() {
        let text = """
        Here are the links you asked for:
        Design Reference
        https://example.com/one
        https://example.com/two
        """
        XCTAssertEqual(PlainTextSignatureRemover.removeSignature(from: text), text)

        let processed = ChatBubbleTextProcessor.process(
            content: text,
            options: ChatBubbleTextProcessorOptions(inputKind: .plainText)
        )
        XCTAssertEqual(
            processed.mainText,
            "Here are the links you asked for:\n\nDesign Reference\n\nhttps://example.com/one\n\nhttps://example.com/two"
        )
    }

    func testUnwrapKeepsLeadingURLLineBreak() {
        // Revert-check: TextProcessing leading URL guard / web text.ts.
        for separator in ["\n", "\n\n"] {
            XCTAssertEqual(
                TextProcessing.unwrapEmailLineBreaks(from: "Emergency line: 914-555-0123" + separator + "www.example.com"),
                "Emergency line: 914-555-0123\n\nwww.example.com"
            )
        }
    }
    func testUnwrapNameCheckDoesNotMatchContactWordsInsideNames() {
        // Revert-check: shared name classifier in TextProcessing / web text.ts.
        XCTAssertEqual(TextProcessing.unwrapEmailLineBreaks(from: "Best,\nMarcella Rossi"), "Best,\nMarcella Rossi")
        XCTAssertEqual(TextProcessing.unwrapEmailLineBreaks(from: "Best,\nMobile Office"), "Best,\n\nMobile Office")
    }
}
