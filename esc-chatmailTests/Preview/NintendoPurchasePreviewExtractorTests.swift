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

    func testIsPurchaseNotice_requiresNintendoSenderAndReceiptFields() {
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
            subject: "Your refund request",
            noticeText: "We have reviewed your request.\n\nOn Nov 1, 2026, Player wrote:\n> \(receipt)"
        ))
        // Nintendo marketing mail that mentions renewal but carries no receipt fields.
        XCTAssertFalse(NintendoPurchasePreviewExtractor.isPurchaseNotice(
            senderEmail: "news@email.nintendo.com",
            subject: "New games are coming to Nintendo Switch Online",
            noticeText: "Make sure your membership is set for automatic renewal so you never miss a release. Unsubscribe"
        ))
    }
}
