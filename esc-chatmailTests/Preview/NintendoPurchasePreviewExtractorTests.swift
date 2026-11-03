import XCTest
@testable import esc_chatmail

final class NintendoPurchasePreviewExtractorTests: XCTestCase {
    private let builder = TransactionalPreviewBuilder()

    func testBuildPreview_nintendoPurchaseReceipt_summarizesMembershipTotalAndTransaction() {
        // Revert-check: removing the `NintendoPurchasePreviewExtractor` branch
        // from `TransactionalPreviewBuilder.buildPreview` titles the card with
        // the subject and reads a how-to line as its subtitle.
        let result = builder.buildPreview(
            canonicalHTML: NintendoNoticeFixtures.html(from: NintendoNoticeFixtures.purchaseBodyText),
            bodyText: NintendoNoticeFixtures.purchaseBodyText,
            senderName: NintendoNoticeFixtures.senderName,
            senderEmail: NintendoNoticeFixtures.senderEmail,
            subject: NintendoNoticeFixtures.purchaseSubject
        )

        XCTAssertEqual(result?.title, "Nintendo Switch Online + Expansion Pack")
        XCTAssertEqual(result?.subtitle, "Individual 12-month (365-day) membership")
        XCTAssertEqual(result?.amount, "$54.36")
        XCTAssertEqual(result?.status, "Purchased")
        XCTAssertEqual(result?.detailLine, "11/1/2026 • Transaction ID 52724694283")
        XCTAssertNil(result?.actionLabel)
        XCTAssertNil(result?.imageURL)
        XCTAssertEqual(result?.sourceLabel, "Nintendo")
        XCTAssertEqual(result?.sourceDomain, "accounts.nintendo.com")
    }

    func testBuildPreview_nintendoAutomaticRenewalNotice_summarizesPriceAndTurnOffDeadline() {
        // Revert-check: removing `automaticRenewalNotice` (or the builder
        // branch) loses the "Auto-Renewal" status and the turn-off deadline.
        let result = builder.buildPreview(
            canonicalHTML: NintendoNoticeFixtures.html(from: NintendoNoticeFixtures.renewalBodyText),
            bodyText: NintendoNoticeFixtures.renewalBodyText,
            senderName: NintendoNoticeFixtures.senderName,
            senderEmail: NintendoNoticeFixtures.senderEmail,
            subject: NintendoNoticeFixtures.renewalSubject
        )

        XCTAssertEqual(result?.title, "Nintendo Switch Online + Expansion Pack")
        XCTAssertEqual(result?.subtitle, "Individual 12-month (365-day) membership")
        XCTAssertEqual(result?.amount, "$49.99")
        XCTAssertEqual(result?.status, "Auto-Renewal")
        XCTAssertEqual(result?.detailLine, "Turn off auto-renewal by 10/30/2027 06:58 PDT")
        XCTAssertEqual(result?.sourceLabel, "Nintendo")
    }

    func testBuildPreview_nintendoNoticeFromHTMLOnly_readsFieldsFromExtractedText() {
        // No plain-text part: the fields come from the HTML-derived text.
        // Revert-check: dropping `extractedText` from
        // `NintendoPurchasePreviewExtractor.noticeText` leaves the plain card.
        let result = builder.buildPreview(
            canonicalHTML: NintendoNoticeFixtures.html(from: NintendoNoticeFixtures.renewalBodyText),
            bodyText: nil,
            senderName: NintendoNoticeFixtures.senderName,
            senderEmail: NintendoNoticeFixtures.senderEmail,
            subject: NintendoNoticeFixtures.renewalSubject
        )

        XCTAssertEqual(result?.title, "Nintendo Switch Online + Expansion Pack")
        XCTAssertEqual(result?.amount, "$49.99")
        XCTAssertEqual(result?.status, "Auto-Renewal")
        XCTAssertEqual(result?.detailLine, "Turn off auto-renewal by 10/30/2027 06:58 PDT")
    }

    func testNoticeText_noPlainOrExtractedText_readsCanonicalHTMLLineByLine() {
        // Revert-check: removing the `canonicalHTML` branch from
        // `NintendoPurchasePreviewExtractor.noticeText` returns "", so the gate refuses.
        let noticeText = NintendoPurchasePreviewExtractor.noticeText(
            plainText: nil,
            extractedText: nil,
            canonicalHTML: NintendoNoticeFixtures.html(from: NintendoNoticeFixtures.renewalBodyText)
        )

        XCTAssertTrue(noticeText.components(separatedBy: .newlines).contains("Automatic renewal term: 365 d"))
        XCTAssertTrue(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: NintendoNoticeFixtures.senderEmail,
            subject: NintendoNoticeFixtures.renewalSubject,
            noticeText: noticeText
        ))
    }

    func testIsPurchaseNotice_nonNintendoSender_doesNotBuildNoticeText() {
        // Revert-check: evaluating `noticeText` ahead of `isNintendoSender` in
        // `isPurchaseNotice` builds the text for every previewed message.
        var builtText = false
        func makeNoticeText() -> String {
            builtText = true
            return NintendoNoticeFixtures.purchaseBodyText
        }

        XCTAssertFalse(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: "friend@example.com",
            subject: NintendoNoticeFixtures.purchaseSubject,
            noticeText: makeNoticeText()
        ))
        XCTAssertFalse(builtText)
    }

    func testIsPurchaseNotice_senderAndFieldCombinations_acceptsOnlyNintendoNotices() {
        // Revert-check: dropping `isNintendoSender` from `isPurchaseNotice` accepts
        // the two foreign senders; dropping `quotedConversationMarkers` or
        // `isReplyOrForwardSubject` from `acceptedKind` accepts the replies.
        let receipt = NintendoNoticeFixtures.purchaseBodyText
        let renewal = NintendoNoticeFixtures.renewalBodyText

        XCTAssertTrue(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: NintendoNoticeFixtures.senderEmail,
            subject: NintendoNoticeFixtures.purchaseSubject,
            noticeText: receipt
        ))
        XCTAssertTrue(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: "Nintendo <noreply@nintendo.net>",
            subject: NintendoNoticeFixtures.renewalSubject,
            noticeText: renewal
        ))

        // Lookalike sender domain.
        XCTAssertFalse(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: "no-reply@accounts.nintendo.com.example.org",
            subject: NintendoNoticeFixtures.purchaseSubject,
            noticeText: receipt
        ))
        // Same receipt fields from someone else.
        XCTAssertFalse(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: "friend@example.com",
            subject: NintendoNoticeFixtures.purchaseSubject,
            noticeText: receipt
        ))
        // A support reply or forward quoting the receipt is a conversation.
        XCTAssertFalse(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: NintendoNoticeFixtures.senderEmail,
            subject: "Re: \(NintendoNoticeFixtures.purchaseSubject)",
            noticeText: receipt
        ))
        XCTAssertFalse(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: "support@nintendo.com",
            subject: "Your request",
            noticeText: "We have reviewed your request.\n\nOn Nov 1, 2026, Player wrote:\n> \(receipt)"
        ))
        // Nintendo marketing mail that mentions renewal but carries no receipt fields.
        XCTAssertFalse(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: "news@email.nintendo.com",
            subject: "New games are coming to Nintendo Switch Online",
            noticeText: "Make sure your membership is set for automatic renewal so you never miss a release. Unsubscribe"
        ))
    }

    func testIsPurchaseNotice_otherOutcomeInSubjectOrLeadIn_returnsFalse() {
        // Revert-check: removing `reportsOtherOutcome` from `isPurchaseNotice`
        // accepts all three, and the card then reads "Purchased" on a refund.
        XCTAssertFalse(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: "support@nintendo.com",
            subject: "Your transaction with Nintendo",
            noticeText: Self.refundBodyText
        ))
        XCTAssertFalse(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: NintendoNoticeFixtures.senderEmail,
            subject: "Your refund has been processed",
            noticeText: NintendoNoticeFixtures.purchaseBodyText
        ))
        XCTAssertFalse(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: NintendoNoticeFixtures.senderEmail,
            subject: "Your membership update",
            noticeText: """
            Automatic renewal for your membership has been turned off.

            Automatic renewal term: 365 d
            Price: $49.99
            """
        ))
    }

    func testIsPurchaseNotice_outcomeWordsBelowTheFields_returnsTrue() {
        // Revert-check: scanning the whole body in `reportsOtherOutcome` rather
        // than the lead-in refuses this genuine receipt over its legal section.
        XCTAssertTrue(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: NintendoNoticeFixtures.senderEmail,
            subject: NintendoNoticeFixtures.purchaseSubject,
            noticeText: NintendoNoticeFixtures.purchaseBodyText
                + "\n\nDigital purchases are not eligible for a refund. Contact Nintendo Support for help."
        ))
    }

    func testIsPurchaseNotice_refundStatedBelowTheFields_returnsFalse() {
        // Revert-check: removing `statedOtherOutcomePattern` from
        // `reportsOtherOutcome` accepts these, and the card reads "Purchased".
        for statement in ["This purchase has been refunded.", "We have refunded this purchase.", "Your payment was declined."] {
            XCTAssertFalse(NintendoPurchasePreviewExtractor.isPurchaseNotice(
                senderEmail: NintendoNoticeFixtures.senderEmail,
                subject: "Your transaction with Nintendo",
                noticeText: """
                Details of your digital purchase from Nintendo.

                Transaction ID: 52724694283
                Price: $49.99

                \(statement)
                """
            ), statement)
        }
    }

    func testBuildPreview_yearFirstTransactionDate_keepsWholeDate() {
        // Revert-check: dropping the `\b` boundaries and year-first alternative
        // from `datePart` shows "26/11/01", read from the middle of the year.
        let bodyText = NintendoNoticeFixtures.purchaseBodyText.replacingOccurrences(
            of: "11/1/2026 05:58:10",
            with: "2026/11/01 05:58:10"
        )
        let result = builder.buildPreview(
            canonicalHTML: NintendoNoticeFixtures.html(from: bodyText),
            bodyText: bodyText,
            senderName: NintendoNoticeFixtures.senderName,
            senderEmail: NintendoNoticeFixtures.senderEmail,
            subject: NintendoNoticeFixtures.purchaseSubject
        )

        XCTAssertEqual(result?.detailLine, "2026/11/01 • Transaction ID 52724694283")
    }

    func testIsPurchaseNotice_transactionIDWithOnlyHowToEShopMention_returnsFalse() {
        // Revert-check: restoring "nintendo eshop" to `purchaseMarkers` accepts
        // this order note, which never says a purchase was made.
        XCTAssertFalse(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: NintendoNoticeFixtures.senderEmail,
            subject: "Your order",
            noticeText: """
            Here is the information about your order.

            Transaction ID: 52724694283

            To check it, open Nintendo eShop.
            """
        ))
    }

    func testBuildPreview_nintendoRefundCarryingReceiptFields_doesNotClaimPurchased() {
        // Revert-check: removing `reportsOtherOutcome` from `isPurchaseNotice`
        // gives this refund the Nintendo card with its fixed "Purchased" status.
        let result = builder.buildPreview(
            canonicalHTML: NintendoNoticeFixtures.html(from: Self.refundBodyText),
            bodyText: Self.refundBodyText,
            senderName: NintendoNoticeFixtures.senderName,
            senderEmail: "support@nintendo.com",
            subject: "Your transaction with Nintendo"
        )

        XCTAssertNotEqual(result?.status, "Purchased")
    }

    private static let refundBodyText = """
    We have refunded your recent digital purchase from Nintendo.

    Transaction ID: 52724694283
    Price: $49.99
    """
}
