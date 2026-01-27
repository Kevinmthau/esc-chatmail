import XCTest
@testable import esc_chatmail

final class MessageProcessorTests: XCTestCase {

    private var processor: MessageProcessor!

    override func setUp() {
        super.setUp()
        processor = MessageProcessor()
    }

    override func tearDown() {
        processor = nil
        super.tearDown()
    }

    // MARK: - Gmail Category Labels

    func testIsNewsletter_gmailPromotionsLabel_doesNotFlagAlone() {
        let headers = ProcessedHeaders()
        let result = processor.calculateNewsletterScore(
            labelIds: ["CATEGORY_PROMOTIONS"],
            headers: headers
        )

        // Gmail CATEGORY_PROMOTIONS alone (40 points) doesn't reach threshold (50)
        // This prevents over-flagging when Gmail's ML might have false positives
        XCTAssertFalse(result.isNewsletter, "Gmail CATEGORY_PROMOTIONS alone should not reach threshold (score 40)")
        XCTAssertEqual(result.score, 40)
        XCTAssertTrue(result.signals.contains(.gmailPromotions))
    }

    func testIsNewsletter_gmailPromotionsWithWeakSignal_flagsAsNewsletter() {
        var headers = ProcessedHeaders()
        headers.replyTo = "different@example.com"
        headers.from = "sender@example.com"

        let result = processor.calculateNewsletterScore(
            labelIds: ["CATEGORY_PROMOTIONS"],
            headers: headers
        )

        // Gmail CATEGORY_PROMOTIONS (40) + reply-to mismatch (10) = 50, at threshold
        XCTAssertTrue(result.isNewsletter, "Gmail CATEGORY_PROMOTIONS with weak corroborating signal should flag")
        XCTAssertEqual(result.score, 50)
        XCTAssertTrue(result.signals.contains(.gmailPromotions))
        XCTAssertTrue(result.signals.contains(.replyToMismatch))
    }

    func testIsNewsletter_gmailUpdatesLabel_doesNotFlagAlone() {
        let headers = ProcessedHeaders()
        let result = processor.calculateNewsletterScore(
            labelIds: ["CATEGORY_UPDATES"],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "Gmail CATEGORY_UPDATES alone should not reach threshold (score 30)")
        XCTAssertEqual(result.score, 30)
        XCTAssertTrue(result.signals.contains(.gmailUpdates))
    }

    func testIsNewsletter_gmailForumsLabel_doesNotFlagAlone() {
        let headers = ProcessedHeaders()
        let result = processor.calculateNewsletterScore(
            labelIds: ["CATEGORY_FORUMS"],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "Gmail CATEGORY_FORUMS alone should not reach threshold (score 20)")
        XCTAssertEqual(result.score, 20)
        XCTAssertTrue(result.signals.contains(.gmailForums))
    }

    // MARK: - Weak Sender Patterns (Should Not Flag Alone)

    func testIsNewsletter_supportAtSenderAlone_doesNotFlag() {
        var headers = ProcessedHeaders()
        headers.from = "support@example.com"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "support@ alone should not flag as newsletter (score 5)")
        XCTAssertEqual(result.score, 5)
        XCTAssertTrue(result.signals.contains(.senderSupport))
    }

    func testIsNewsletter_helloAtSenderAlone_doesNotFlag() {
        var headers = ProcessedHeaders()
        headers.from = "hello@company.com"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "hello@ alone should not flag as newsletter")
        XCTAssertEqual(result.score, 5)
    }

    func testIsNewsletter_teamAtSenderAlone_doesNotFlag() {
        var headers = ProcessedHeaders()
        headers.from = "team@startup.io"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "team@ alone should not flag as newsletter")
        XCTAssertEqual(result.score, 5)
    }

    func testIsNewsletter_infoAtSenderAlone_doesNotFlag() {
        var headers = ProcessedHeaders()
        headers.from = "info@business.com"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "info@ alone should not flag as newsletter")
        XCTAssertEqual(result.score, 5)
    }

    // MARK: - Combined Weak Signals

    func testIsNewsletter_supportAtWithListUnsubscribe_flagsAsNewsletter() {
        var headers = ProcessedHeaders()
        headers.from = "support@example.com"
        headers.listUnsubscribe = "<mailto:unsubscribe@example.com>"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        // support@ (5) + listUnsubscribe (35) = 40, still below 50
        XCTAssertFalse(result.isNewsletter, "support@ + listUnsubscribe should score 40, not reach threshold")
        XCTAssertEqual(result.score, 40)
    }

    func testIsNewsletter_multipleWeakSignals_flagsAsNewsletter() {
        var headers = ProcessedHeaders()
        headers.from = "notifications@example.com"  // 20 points
        headers.listId = "<list.example.com>"       // 25 points
        headers.replyTo = "different@example.com"   // 10 points (mismatch)

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        // notifications@ (20) + listId (25) + replyTo mismatch (10) = 55
        XCTAssertTrue(result.isNewsletter, "Combined weak signals should reach threshold")
        XCTAssertGreaterThanOrEqual(result.score, 50)
    }

    // MARK: - Recipient Count Thresholds

    func testIsNewsletter_tenRecipients_doesNotFlag() {
        var headers = ProcessedHeaders()
        headers.to = (1...10).map { EmailAddress(email: "user\($0)@example.com", displayName: nil) }

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "10 recipients should not trigger recipient count signal")
        XCTAssertEqual(result.score, 0)
    }

    func testIsNewsletter_twentyFiveRecipients_doesNotFlagAlone() {
        var headers = ProcessedHeaders()
        headers.to = (1...25).map { EmailAddress(email: "user\($0)@example.com", displayName: nil) }

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "25 recipients alone should not reach threshold (score 15)")
        XCTAssertEqual(result.score, 15)
        XCTAssertTrue(result.signals.contains(.highRecipientCount))
    }

    func testIsNewsletter_fiftyFiveRecipients_doesNotFlagAlone() {
        var headers = ProcessedHeaders()
        headers.to = (1...55).map { EmailAddress(email: "user\($0)@example.com", displayName: nil) }

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "55 recipients alone should not reach threshold (score 25)")
        XCTAssertEqual(result.score, 25)
        XCTAssertTrue(result.signals.contains(.veryHighRecipientCount))
    }

    // MARK: - Subject Pattern Tests

    func testIsNewsletter_weeklyInSubjectAlone_doesNotFlag() {
        var headers = ProcessedHeaders()
        headers.subject = "Weekly team meeting notes"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "weekly in subject alone should not flag (score 5)")
        XCTAssertEqual(result.score, 5)
        XCTAssertTrue(result.signals.contains(.subjectPeriodic))
    }

    func testIsNewsletter_monthlyInSubjectAlone_doesNotFlag() {
        var headers = ProcessedHeaders()
        headers.subject = "Monthly report - January"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "monthly in subject alone should not flag (score 5)")
        XCTAssertEqual(result.score, 5)
    }

    func testIsNewsletter_discountInSubject_doesNotFlagAlone() {
        var headers = ProcessedHeaders()
        headers.subject = "50% off everything today!"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "discount in subject alone should not reach threshold (score 15)")
        XCTAssertEqual(result.score, 15)
        XCTAssertTrue(result.signals.contains(.subjectDiscount))
    }

    func testIsNewsletter_newsletterInSubject_doesNotFlagAlone() {
        var headers = ProcessedHeaders()
        headers.subject = "Our Newsletter - March Edition"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "newsletter in subject alone should not reach threshold (score 20)")
        XCTAssertEqual(result.score, 20)
        XCTAssertTrue(result.signals.contains(.subjectNewsletter))
    }

    // MARK: - Strong Sender Patterns

    func testIsNewsletter_noreplyAtSender_doesNotFlagAlone() {
        var headers = ProcessedHeaders()
        headers.from = "noreply@example.com"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "noreply@ alone should not reach threshold (score 25)")
        XCTAssertEqual(result.score, 25)
        XCTAssertTrue(result.signals.contains(.senderNoreply))
    }

    func testIsNewsletter_newsletterAtSender_doesNotFlagAlone() {
        var headers = ProcessedHeaders()
        headers.from = "newsletter@company.com"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "newsletter@ alone should not reach threshold (score 35)")
        XCTAssertEqual(result.score, 35)
        XCTAssertTrue(result.signals.contains(.senderNewsletter))
    }

    func testIsNewsletter_marketingAtSender_doesNotFlagAlone() {
        var headers = ProcessedHeaders()
        headers.from = "marketing@brand.com"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "marketing@ alone should not reach threshold (score 35)")
        XCTAssertEqual(result.score, 35)
    }

    // MARK: - Mailing List Headers

    func testIsNewsletter_listUnsubscribeHeader_doesNotFlagAlone() {
        var headers = ProcessedHeaders()
        headers.listUnsubscribe = "<mailto:unsubscribe@list.example.com>"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "List-Unsubscribe alone should not reach threshold (score 35)")
        XCTAssertEqual(result.score, 35)
        XCTAssertTrue(result.signals.contains(.listUnsubscribe))
    }

    func testIsNewsletter_listIdHeader_doesNotFlagAlone() {
        var headers = ProcessedHeaders()
        headers.listId = "<list-123.example.com>"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "List-Id alone should not reach threshold (score 25)")
        XCTAssertEqual(result.score, 25)
        XCTAssertTrue(result.signals.contains(.listId))
    }

    func testIsNewsletter_listUnsubscribeAndListId_flagsAsNewsletter() {
        var headers = ProcessedHeaders()
        headers.listUnsubscribe = "<mailto:unsubscribe@list.example.com>"
        headers.listId = "<list-123.example.com>"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        // listUnsubscribe (35) + listId (25) = 60
        XCTAssertTrue(result.isNewsletter, "List-Unsubscribe + List-Id should flag as newsletter")
        XCTAssertEqual(result.score, 60)
    }

    // MARK: - Precedence Header

    func testIsNewsletter_precedenceBulk_doesNotFlagAlone() {
        var headers = ProcessedHeaders()
        headers.precedence = "bulk"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "Precedence: bulk alone should not reach threshold (score 30)")
        XCTAssertEqual(result.score, 30)
        XCTAssertTrue(result.signals.contains(.precedenceBulk))
    }

    func testIsNewsletter_precedenceList_doesNotFlagAlone() {
        var headers = ProcessedHeaders()
        headers.precedence = "list"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "Precedence: list alone should not reach threshold (score 30)")
        XCTAssertEqual(result.score, 30)
    }

    // MARK: - Real-World Scenarios

    func testIsNewsletter_typicalMarketingEmail_flagsCorrectly() {
        var headers = ProcessedHeaders()
        headers.from = "newsletter@store.com"           // 35
        headers.listUnsubscribe = "<mailto:unsub@store.com>"  // 35
        headers.subject = "50% off sale - limited time!"      // 15 + 20

        let result = processor.calculateNewsletterScore(
            labelIds: ["CATEGORY_PROMOTIONS"],          // 40
            headers: headers
        )

        XCTAssertTrue(result.isNewsletter, "Typical marketing email should flag as newsletter")
        XCTAssertGreaterThan(result.score, 100)
    }

    func testIsNewsletter_legitimateSupportEmail_doesNotFlag() {
        var headers = ProcessedHeaders()
        headers.from = "Support Team <support@company.com>"
        headers.subject = "Re: Your ticket #12345"
        headers.to = [EmailAddress(email: "customer@example.com", displayName: "Customer")]

        let result = processor.calculateNewsletterScore(
            labelIds: ["INBOX"],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "Legitimate support email should not flag")
        XCTAssertEqual(result.score, 5) // Only support@ pattern
    }

    func testIsNewsletter_personalEmailFromHello_doesNotFlag() {
        var headers = ProcessedHeaders()
        headers.from = "Jane Doe <hello@janedoe.com>"
        headers.subject = "Catching up"
        headers.to = [EmailAddress(email: "friend@example.com", displayName: "Friend")]

        let result = processor.calculateNewsletterScore(
            labelIds: ["INBOX"],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter, "Personal email from hello@ should not flag")
        XCTAssertEqual(result.score, 5)
    }

    func testIsNewsletter_transactionalEmailFromNoreply_mayFlag() {
        var headers = ProcessedHeaders()
        headers.from = "noreply@bank.com"               // 25
        headers.subject = "Your monthly statement"      // 5
        headers.listUnsubscribe = nil
        headers.listId = nil

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        // noreply (25) + monthly (5) = 30, below threshold
        XCTAssertFalse(result.isNewsletter, "Transactional email should not flag with weak signals")
        XCTAssertEqual(result.score, 30)
    }

    // MARK: - Edge Cases

    func testIsNewsletter_noSignals_doesNotFlag() {
        let headers = ProcessedHeaders()
        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        XCTAssertFalse(result.isNewsletter)
        XCTAssertEqual(result.score, 0)
        XCTAssertTrue(result.signals.isEmpty)
    }

    func testIsNewsletter_exactlyAtThreshold_flagsAsNewsletter() {
        var headers = ProcessedHeaders()
        // Gmail promotions (40) + reply-to mismatch (10) = 50 exactly
        headers.from = "sender@example.com"
        headers.replyTo = "different@example.com"

        let result = processor.calculateNewsletterScore(
            labelIds: ["CATEGORY_PROMOTIONS"],
            headers: headers
        )

        XCTAssertTrue(result.isNewsletter, "Score of exactly 50 should flag as newsletter")
        XCTAssertEqual(result.score, 50)
    }

    func testIsNewsletter_justBelowThreshold_doesNotFlag() {
        var headers = ProcessedHeaders()
        // Gmail updates (30) + sender notifications (20) = 50, but we need to test 49
        // Using: listId (25) + notifications@ (20) = 45
        headers.from = "notifications@example.com"
        headers.listId = "<list.example.com>"

        let result = processor.calculateNewsletterScore(
            labelIds: [],
            headers: headers
        )

        // notifications@ (20) + listId (25) = 45
        XCTAssertFalse(result.isNewsletter, "Score of 45 should not flag as newsletter")
        XCTAssertEqual(result.score, 45)
    }
}
