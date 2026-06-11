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

    // MARK: - Canonical MIME Content

    func testProcessGmailMessage_multipartAlternativePlainFirstPersistsHTMLAsCanonicalSource() async throws {
        let html = """
        <!DOCTYPE html><html><body><table><tr><td><a href="https://example.com/book">Book now</a></td></tr></table></body></html>
        """
        let plainText = """
        https://tracking.example.com/one
        https://tracking.example.com/two
        Book now
        """

        let message = makeMultipartAlternativeMessage(
            id: "multipart-plain-first",
            plainText: plainText,
            html: html,
            plainFirst: true
        )

        let processedMessage = await processor.processGmailMessage(message, myAliases: [])
        let processed = try XCTUnwrap(processedMessage)

        XCTAssertEqual(processed.htmlBody, html)
        XCTAssertEqual(processed.canonicalContent?.html, html)
        XCTAssertTrue(processed.canonicalContent?.hasHTMLSource == true)
        XCTAssertEqual(processed.canonicalContent?.sourceKind, .html)
        XCTAssertEqual(processed.plainTextBody, plainText)
    }

    func testProcessGmailMessage_multipartAlternativeHTMLFirstPersistsHTMLAsCanonicalSource() async throws {
        let html = """
        <!DOCTYPE html><html><body><table><tr><td><img src="https://example.com/hero.jpg"><a href="https://example.com/book">Book now</a></td></tr></table></body></html>
        """
        let plainText = """
        https://tracking.example.com/one
        https://tracking.example.com/two
        Book now
        """

        let message = makeMultipartAlternativeMessage(
            id: "multipart-html-first",
            plainText: plainText,
            html: html,
            plainFirst: false
        )

        let processedMessage = await processor.processGmailMessage(message, myAliases: [])
        let processed = try XCTUnwrap(processedMessage)

        XCTAssertEqual(processed.htmlBody, html)
        XCTAssertEqual(processed.canonicalContent?.html, html)
        XCTAssertTrue(processed.canonicalContent?.hasHTMLSource == true)
        XCTAssertEqual(processed.canonicalContent?.sourceKind, .html)
        XCTAssertEqual(processed.plainTextBody, plainText)
    }

    func testProcessGmailMessage_multipartMixedTextAttachmentBeforeAlternativeUsesBodyText() async throws {
        let attachmentText = "ATTACHMENT_TOKEN_NOT_BODY"
        let plainText = "REAL_BODY_TOKEN\nThanks"
        let html = "<html><body><p>REAL_BODY_TOKEN</p><p>Thanks</p></body></html>"

        let message = makeMultipartMessage(
            id: "text-attachment-before-alternative",
            parts: [
                MessagePart(
                    partId: "0.0",
                    mimeType: "text/plain",
                    filename: "notes.txt",
                    headers: [
                        MessageHeader(name: "Content-Type", value: "text/plain; charset=utf-8"),
                        MessageHeader(name: "Content-Disposition", value: "attachment; filename=\"notes.txt\"")
                    ],
                    body: MessageBody(
                        size: attachmentText.count,
                        data: Data(attachmentText.utf8).base64EncodedString(),
                        attachmentId: nil
                    ),
                    parts: nil
                ),
                MessagePart(
                    partId: "0.1",
                    mimeType: "multipart/alternative",
                    filename: nil,
                    headers: nil,
                    body: nil,
                    parts: [
                        MessagePart(
                            partId: "0.1.0",
                            mimeType: "text/plain",
                            filename: nil,
                            headers: [
                                MessageHeader(name: "Content-Type", value: "text/plain; charset=utf-8")
                            ],
                            body: MessageBody(
                                size: plainText.count,
                                data: Data(plainText.utf8).base64EncodedString(),
                                attachmentId: nil
                            ),
                            parts: nil
                        ),
                        MessagePart(
                            partId: "0.1.1",
                            mimeType: "text/html",
                            filename: nil,
                            headers: [
                                MessageHeader(name: "Content-Type", value: "text/html; charset=utf-8")
                            ],
                            body: MessageBody(
                                size: html.count,
                                data: Data(html.utf8).base64EncodedString(),
                                attachmentId: nil
                            ),
                            parts: nil
                        )
                    ]
                )
            ]
        )

        let processedMessage = await processor.processGmailMessage(message, myAliases: [])
        let processed = try XCTUnwrap(processedMessage)

        XCTAssertEqual(processed.htmlBody, html)
        XCTAssertEqual(processed.plainTextBody, plainText)
        XCTAssertEqual(processed.canonicalContent?.plainText, plainText)
        XCTAssertEqual(processed.attachmentInfo.first?.filename, "notes.txt")
        XCTAssertFalse(processed.cleanedSnippet?.contains(attachmentText) == true)
    }

    func testProcessGmailMessage_multipartMixedTrailingPlainTextDoesNotOverrideBody() async throws {
        let bodyText = "REAL_BODY_TOKEN\nThanks"
        let trailingText = "TRAILING_GENERATED_TOKEN"

        let message = makeMultipartMessage(
            id: "trailing-plain-text-does-not-override-body",
            parts: [
                MessagePart(
                    partId: "0.0",
                    mimeType: "text/plain",
                    filename: nil,
                    headers: [
                        MessageHeader(name: "Content-Type", value: "text/plain; charset=utf-8")
                    ],
                    body: MessageBody(
                        size: bodyText.count,
                        data: Data(bodyText.utf8).base64EncodedString(),
                        attachmentId: nil
                    ),
                    parts: nil
                ),
                MessagePart(
                    partId: "0.1",
                    mimeType: "text/plain",
                    filename: nil,
                    headers: [
                        MessageHeader(name: "Content-Type", value: "text/plain; charset=utf-8")
                    ],
                    body: MessageBody(
                        size: trailingText.count,
                        data: Data(trailingText.utf8).base64EncodedString(),
                        attachmentId: nil
                    ),
                    parts: nil
                )
            ]
        )

        let processedMessage = await processor.processGmailMessage(message, myAliases: [])
        let processed = try XCTUnwrap(processedMessage)

        XCTAssertEqual(processed.plainTextBody, bodyText)
        XCTAssertEqual(processed.canonicalContent?.plainText, bodyText)
        XCTAssertFalse(processed.cleanedSnippet?.contains(trailingText) == true)
    }

    func testProcessGmailMessage_populatesChatPreviewTextFromHTMLPreservingParagraphs() async throws {
        let html = """
        <html>
        <body>
          <p>First paragraph.</p>
          <p>Second paragraph. Thanks, Kevin</p>
        </body>
        </html>
        """
        let plainText = "Plain fallback should not win"

        let message = makeMultipartAlternativeMessage(
            id: "chat-preview-html-paragraphs",
            plainText: plainText,
            html: html,
            plainFirst: true
        )

        let processedMessage = await processor.processGmailMessage(message, myAliases: [])
        let processed = try XCTUnwrap(processedMessage)
        let chatPreviewText = try XCTUnwrap(processed.chatPreviewText)

        XCTAssertTrue(chatPreviewText.contains("First paragraph."))
        XCTAssertTrue(chatPreviewText.contains("\n\nSecond paragraph."))
        XCTAssertTrue(chatPreviewText.contains("Thanks"))
        XCTAssertTrue(chatPreviewText.contains("\nKevin"))
        XCTAssertFalse(chatPreviewText.contains(plainText))
        XCTAssertFalse(processed.cleanedSnippet?.contains("\n") == true)
    }

    func testProcessGmailMessage_chatPreviewTextStripsQuotedHTMLContent() async throws {
        let html = """
        <html>
        <body>
          <div>Fresh reply body.</div>
          <blockquote>
            <div>QUOTED_ORIGINAL_TOKEN</div>
          </blockquote>
        </body>
        </html>
        """

        let message = makeMultipartAlternativeMessage(
            id: "chat-preview-strips-quoted-html",
            plainText: "Fresh reply body.\n\n> QUOTED_ORIGINAL_TOKEN",
            html: html,
            plainFirst: false
        )

        let processedMessage = await processor.processGmailMessage(message, myAliases: [])
        let processed = try XCTUnwrap(processedMessage)

        XCTAssertEqual(processed.chatPreviewText, "Fresh reply body.")
        XCTAssertFalse(processed.chatPreviewText?.contains("QUOTED_ORIGINAL_TOKEN") == true)
    }

    func testProcessGmailMessage_outgoingForwardWithoutUserBodyDoesNotUseForwardedHTMLAsChatPreview() async throws {
        let plainText = """

        ---------- Forwarded message ---------
        From: Park Avenue Armory <news@armoryonpark.org>
        Date: Jun 10, 2026 at 5:33 PM
        Subject: Now on View: Celeste Boursier-Mougenot's "clinamen"
        To: solutions@armoryonpark.org

        Experience the largest iteration of the aquatic and musical installation now through August 2.
        Additional support has been provided by the Armory's Artistic Council.
        """
        let html = """
        <html>
        <body>
          <p>Additional support has been provided by the Armory's Artistic Council.</p>
          <div>---------- Forwarded message ---------</div>
          <div>From: Park Avenue Armory &lt;news@armoryonpark.org&gt;</div>
          <div>Date: Jun 10, 2026 at 5:33 PM</div>
          <div>Subject: Now on View: Celeste Boursier-Mougenot's "clinamen"</div>
          <p>Experience the largest iteration of the aquatic and musical installation now through August 2.</p>
        </body>
        </html>
        """

        let message = GmailMessageBuilder()
            .withId("outgoing-forward-empty-note")
            .sent()
            .withFrom("me@example.com", name: "Me")
            .withSubject("Fwd: Now on View: Celeste Boursier-Mougenot's \"clinamen\"")
            .withSnippet("Additional support has been provided by the Armory's Artistic Council.")
            .withBodyText(plainText)
            .withBodyHtml(html)
            .build()

        let processedMessage = await processor.processGmailMessage(message, myAliases: ["me@example.com"])
        let processed = try XCTUnwrap(processedMessage)

        XCTAssertTrue(processed.headers.isFromMe)
        XCTAssertNil(processed.chatPreviewText)
        XCTAssertTrue(processed.plainTextBody?.contains("---------- Forwarded message ---------") == true)
    }

    func testProcessGmailMessage_outgoingForwardWithUserBodyUsesPlainTextLeadInAsChatPreview() async throws {
        let plainText = """
        FYI

        ---------- Forwarded message ---------
        From: Park Avenue Armory <news@armoryonpark.org>
        Date: Jun 10, 2026 at 5:33 PM
        Subject: Now on View

        Experience the largest iteration of the aquatic and musical installation now through August 2.
        """
        let html = """
        <html>
        <body>
          <p>Experience the largest iteration of the aquatic and musical installation now through August 2.</p>
          <div>---------- Forwarded message ---------</div>
          <div>From: Park Avenue Armory &lt;news@armoryonpark.org&gt;</div>
          <div>Subject: Now on View</div>
        </body>
        </html>
        """

        let message = GmailMessageBuilder()
            .withId("outgoing-forward-with-note")
            .sent()
            .withFrom("me@example.com", name: "Me")
            .withSubject("Fwd: Now on View")
            .withSnippet("FYI ---------- Forwarded message ---------")
            .withBodyText(plainText)
            .withBodyHtml(html)
            .build()

        let processedMessage = await processor.processGmailMessage(message, myAliases: ["me@example.com"])
        let processed = try XCTUnwrap(processedMessage)

        XCTAssertEqual(processed.chatPreviewText, "FYI")
    }

    func testProcessGmailMessage_outgoingForwardSubjectWithoutForwardMarkerUsesNormalPreviewFallback() async throws {
        let message = GmailMessageBuilder()
            .withId("outgoing-forward-subject-without-marker")
            .sent()
            .withFrom("me@example.com", name: "Me")
            .withSubject("Fwd: Status")
            .withBodyText("Plain fallback should not win")
            .withBodyHtml("<html><body><p>Regular sent body.</p></body></html>")
            .build()

        let processedMessage = await processor.processGmailMessage(message, myAliases: ["me@example.com"])
        let processed = try XCTUnwrap(processedMessage)

        XCTAssertEqual(processed.chatPreviewText, "Regular sent body.")
    }

    func testProcessGmailMessage_cleanedSnippetRemainsCompactWhenChatPreviewHasLineBreaks() async throws {
        let plainText = """
        Line one.

        Line two.
        """

        let message = GmailMessageBuilder()
            .withId("chat-preview-plain-compact-snippet")
            .withSnippet("Line one. Line two.")
            .withBodyText(plainText)
            .build()

        let processedMessage = await processor.processGmailMessage(message, myAliases: [])
        let processed = try XCTUnwrap(processedMessage)

        XCTAssertEqual(processed.chatPreviewText, "Line one.\n\nLine two.")
        XCTAssertEqual(processed.cleanedSnippet, "Line one. Line two.")
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

    func testProcessGmailMessage_promotesInstitutionalSecurityUpdateFromHTMLContent() async {
        let filler = String(repeating: "<p>Security guidance content block.</p>", count: 400)
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <div id="emailPreHeader" style="display:none">Secure your mobile phone in minutes</div>
            <table><tr><td><a href="https://pb.jpmorgan.com/home"><img src="https://pages-pb.jpmorgan.com/logo.png" width="640" height="77" alt="J.P. Morgan Private Bank"></a></td></tr></table>
            <table><tr><td><img src="https://pages-pb.jpmorgan.com/lock.jpg" width="160" height="160" alt="Lock icon"></td><td><h2>Enable extra security at sign-in on mobile</h2><p>Use your device passcode each time for stronger sign-in.</p><a href="https://pb.jpmorgan.com/passcode">Enable device passcode</a></td></tr></table>
            <table><tr><td><img src="https://pages-pb.jpmorgan.com/fingerprint.jpg" width="160" height="160" alt="Fingerprint"></td><td><h2>Use biometrics instead of usernames and passwords</h2><p>Sign in with Face ID or fingerprint for stronger protection.</p><a href="https://pb.jpmorgan.com/biometrics">Turn on biometrics</a></td></tr></table>
            <table><tr><td><img src="https://pages-pb.jpmorgan.com/phone.jpg" width="160" height="160" alt="Mobile phone"></td><td><h2>Sign in regularly to your mobile app to keep your device trusted</h2><p>A trusted device helps us confirm it's you when you call your Client Service team.</p><a href="https://pb.jpmorgan.com/app">Download the app</a></td></tr></table>
            <table><tr><td><h2>Stay one step ahead: Smart habits for stronger mobile security</h2><p>Mobile phones are a prime target for fraud. These tips can help keep your phone safe.</p><a href="https://pb.jpmorgan.com/article">Read article</a></td></tr></table>
            \(filler)
            <table><tr><td><a href="https://pb.jpmorgan.com/privacy">Privacy Policy</a> <a href="https://pb.jpmorgan.com/finra">FINRA</a> <a href="https://pb.jpmorgan.com/sipc">SIPC</a> <a href="https://pb.jpmorgan.com/legal">Important information</a> <a href="https://pb.jpmorgan.com/contact">Contact us</a></td></tr></table>
        </body>
        </html>
        """

        var weakHeaders = ProcessedHeaders()
        weakHeaders.from = "\"J.P. Morgan Private Bank\" <private_banking@pb.jpmorgan.com>"
        weakHeaders.replyTo = "private_banking@jpmorgan.com"
        weakHeaders.subject = "Quick steps to strengthen your mobile security"

        let headerOnlyResult = processor.calculateNewsletterScore(
            labelIds: ["CATEGORY_UPDATES"],
            headers: weakHeaders
        )

        XCTAssertFalse(headerOnlyResult.isNewsletter)

        let plainText = """
        ${Body-Copy-Text}
        ${Body-Strong-Copy-Text}
        ${Article-Headline}
        """

        let message = GmailMessage(
            id: "jpm-security-update",
            threadId: "jpm-security-thread",
            labelIds: ["INBOX", "CATEGORY_UPDATES"],
            snippet: "Secure your mobile phone in minutes",
            historyId: "123",
            internalDate: "1775658731000",
            payload: MessagePart(
                partId: "0",
                mimeType: "multipart/alternative",
                filename: nil,
                headers: [
                    MessageHeader(name: "Subject", value: "Quick steps to strengthen your mobile security"),
                    MessageHeader(name: "From", value: "\"J.P. Morgan Private Bank\" <private_banking@pb.jpmorgan.com>"),
                    MessageHeader(name: "Reply-To", value: "private_banking@jpmorgan.com"),
                    MessageHeader(name: "To", value: "kmthau@gmail.com"),
                    MessageHeader(name: "Date", value: "Wed, 8 Apr 2026 09:32:11 -0500"),
                    MessageHeader(name: "Message-ID", value: "<jpm-security@test.example.com>")
                ],
                body: nil,
                parts: [
                    MessagePart(
                        partId: "0.0",
                        mimeType: "text/plain",
                        filename: nil,
                        headers: [
                            MessageHeader(name: "Content-Type", value: "text/plain; charset=UTF-8")
                        ],
                        body: MessageBody(
                            size: plainText.count,
                            data: plainText.data(using: .utf8)?.base64EncodedString(),
                            attachmentId: nil
                        ),
                        parts: nil
                    ),
                    MessagePart(
                        partId: "0.1",
                        mimeType: "text/html",
                        filename: nil,
                        headers: [
                            MessageHeader(name: "Content-Type", value: "text/html; charset=UTF-8")
                        ],
                        body: MessageBody(
                            size: html.count,
                            data: html.data(using: .utf8)?.base64EncodedString(),
                            attachmentId: nil
                        ),
                        parts: nil
                    )
                ]
            ),
            sizeEstimate: html.count + plainText.count
        )

        let processed = await processor.processGmailMessage(
            message,
            myAliases: []
        )

        XCTAssertTrue(processed?.isNewsletter == true)
        XCTAssertTrue(processed?.htmlBody?.contains("Stay one step ahead") == true)
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

    // MARK: - Attachment Extraction

    func testProcessGmailMessage_extractsInlineDataAttachmentWithoutAttachmentId() async throws {
        let inlineImageData = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2foAAAAASUVORK5CYII="))
        let message = makeMultipartMessage(
            id: "inline-data-attachment-message",
            parts: [
                MessagePart(
                    partId: "0",
                    mimeType: "text/plain",
                    filename: nil,
                    headers: nil,
                    body: MessageBody(
                        size: 12,
                        data: Data("Hello world!".utf8).base64EncodedString(),
                        attachmentId: nil
                    ),
                    parts: nil
                ),
                MessagePart(
                    partId: "1",
                    mimeType: "image/png",
                    filename: "preview.png",
                    headers: [
                        MessageHeader(name: "Content-Disposition", value: "attachment; filename=\"preview.png\""),
                        MessageHeader(name: "Content-ID", value: "<inline-preview>")
                    ],
                    body: MessageBody(
                        size: inlineImageData.count,
                        data: inlineImageData.base64EncodedString(),
                        attachmentId: nil
                    ),
                    parts: nil
                )
            ]
        )

        let processed = await processor.processGmailMessage(
            message,
            myAliases: []
        )

        let attachment = try XCTUnwrap(processed?.attachmentInfo.first)
        XCTAssertEqual(processed?.attachmentInfo.count, 1)
        XCTAssertTrue(processed?.hasAttachments == true)
        XCTAssertTrue(attachment.id.hasPrefix("local_inline_"))
        XCTAssertEqual(attachment.filename, "preview.png")
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(attachment.contentId, "inline-preview")
        XCTAssertEqual(attachment.inlineData, inlineImageData)
    }

    func testProcessGmailMessage_extractsInlineCIDImageWithoutFilename() async throws {
        let inlineImageData = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2foAAAAASUVORK5CYII="))
        let message = makeMultipartMessage(
            id: "inline-cid-no-filename-message",
            parts: [
                MessagePart(
                    partId: "0",
                    mimeType: "text/plain",
                    filename: nil,
                    headers: nil,
                    body: MessageBody(
                        size: 2,
                        data: Data("Hi".utf8).base64EncodedString(),
                        attachmentId: nil
                    ),
                    parts: nil
                ),
                MessagePart(
                    partId: "1",
                    mimeType: "image/png",
                    filename: "",
                    headers: [
                        MessageHeader(name: "Content-Disposition", value: "inline"),
                        MessageHeader(name: "Content-ID", value: "<cid-without-filename>")
                    ],
                    body: MessageBody(
                        size: inlineImageData.count,
                        data: inlineImageData.base64EncodedString(),
                        attachmentId: nil
                    ),
                    parts: nil
                )
            ]
        )

        let processed = await processor.processGmailMessage(
            message,
            myAliases: []
        )

        let attachment = try XCTUnwrap(processed?.attachmentInfo.first)
        XCTAssertEqual(processed?.attachmentInfo.count, 1)
        XCTAssertTrue(processed?.hasAttachments == true)
        XCTAssertEqual(attachment.filename, "attachment.png")
        XCTAssertEqual(attachment.contentId, "cid-without-filename")
        XCTAssertEqual(attachment.inlineData, inlineImageData)
    }

    func testProcessGmailMessage_appleMailMultipartRelatedInlineImage_extractsSingleAttachment() async {
        let contentID = "6AFCA8C9-D2EF-4407-BD15-8D9F042220E9"
        let plainBody = "\u{FFFC}\n\nRICK THAU\nCarmel, CA\nrick@thau.net\nCell: 650-255-5222"
        let htmlBody = """
        <html><body>
        <img src="cid:\(contentID)" alt="IMG_6161.jpeg" type="application/x-apple-msg-attachment">
        <div><b>RICK THAU</b></div>
        <div>Carmel, CA</div>
        </body></html>
        """
        let inlineJPEGData = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()

        let message = GmailMessage(
            id: "apple-mail-inline-image-message",
            threadId: "apple-mail-inline-image-thread",
            labelIds: ["INBOX"],
            snippet: "Happy Pesach",
            historyId: "123",
            internalDate: "1704067200000",
            payload: MessagePart(
                partId: "0",
                mimeType: "multipart/alternative",
                filename: nil,
                headers: baseHeaders(id: "apple-mail-inline-image-message"),
                body: nil,
                parts: [
                    MessagePart(
                        partId: "0.0",
                        mimeType: "text/plain",
                        filename: nil,
                        headers: nil,
                        body: MessageBody(
                            size: plainBody.count,
                            data: plainBody.data(using: .utf8)?.base64EncodedString(),
                            attachmentId: nil
                        ),
                        parts: nil
                    ),
                    MessagePart(
                        partId: "0.1",
                        mimeType: "multipart/related",
                        filename: nil,
                        headers: [
                            MessageHeader(name: "Content-Type", value: "multipart/related")
                        ],
                        body: nil,
                        parts: [
                            MessagePart(
                                partId: "0.1.0",
                                mimeType: "text/html",
                                filename: nil,
                                headers: [
                                    MessageHeader(name: "Content-Transfer-Encoding", value: "quoted-printable")
                                ],
                                body: MessageBody(
                                    size: htmlBody.count,
                                    data: htmlBody.data(using: .utf8)?.base64EncodedString(),
                                    attachmentId: nil
                                ),
                                parts: nil
                            ),
                            MessagePart(
                                partId: "0.1.1",
                                mimeType: "image/jpeg",
                                filename: "IMG_6161.jpeg",
                                headers: [
                                    MessageHeader(name: "Content-Disposition", value: "inline; filename=\"IMG_6161.jpeg\""),
                                    MessageHeader(name: "Content-ID", value: "<\(contentID)>")
                                ],
                                body: MessageBody(
                                    size: 4,
                                    data: inlineJPEGData,
                                    attachmentId: nil
                                ),
                                parts: nil
                            )
                        ]
                    )
                ]
            ),
            sizeEstimate: plainBody.count + htmlBody.count + 4
        )

        let processed = await processor.processGmailMessage(
            message,
            myAliases: []
        )

        XCTAssertEqual(processed?.attachmentInfo.count, 1)
        XCTAssertEqual(processed?.attachmentInfo.first?.filename, "IMG_6161.jpeg")
        XCTAssertEqual(processed?.attachmentInfo.first?.contentId, contentID)
        XCTAssertTrue(processed?.htmlBody?.contains("cid:\(contentID)") == true)
    }

    func testProcessGmailMessage_appleMailMultipartMixed_trailingEmptyPlainTextDoesNotOverrideBody() async {
        let quotedPrintableBody = "Let=E2=80=99s gooooi"
        let inlineJPEGData = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()

        let message = GmailMessage(
            id: "apple-mail-trailing-empty-plain-text",
            threadId: "apple-mail-trailing-empty-plain-text-thread",
            labelIds: ["INBOX"],
            snippet: "Let&#39;s gooooi",
            historyId: "123",
            internalDate: "1776181859209",
            payload: MessagePart(
                partId: "0",
                mimeType: "multipart/mixed",
                filename: nil,
                headers: baseHeaders(id: "apple-mail-trailing-empty-plain-text"),
                body: nil,
                parts: [
                    MessagePart(
                        partId: "0.0",
                        mimeType: "text/plain",
                        filename: nil,
                        headers: [
                            MessageHeader(name: "Content-Type", value: "text/plain; charset=utf-8"),
                            MessageHeader(name: "Content-Transfer-Encoding", value: "quoted-printable")
                        ],
                        body: MessageBody(
                            size: quotedPrintableBody.count,
                            data: quotedPrintableBody.data(using: .utf8)?.base64EncodedString(),
                            attachmentId: nil
                        ),
                        parts: nil
                    ),
                    MessagePart(
                        partId: "0.1",
                        mimeType: "image/jpeg",
                        filename: "image0.jpeg",
                        headers: [
                            MessageHeader(name: "Content-Disposition", value: "inline; filename=\"image0.jpeg\"")
                        ],
                        body: MessageBody(
                            size: 4,
                            data: inlineJPEGData,
                            attachmentId: nil
                        ),
                        parts: nil
                    ),
                    MessagePart(
                        partId: "0.2",
                        mimeType: "text/plain",
                        filename: nil,
                        headers: [
                            MessageHeader(name: "Content-Type", value: "text/plain; charset=us-ascii"),
                            MessageHeader(name: "Content-Transfer-Encoding", value: "7bit")
                        ],
                        body: MessageBody(
                            size: 0,
                            data: Data().base64EncodedString(),
                            attachmentId: nil
                        ),
                        parts: nil
                    )
                ]
            ),
            sizeEstimate: quotedPrintableBody.count + 4
        )

        let processed = await processor.processGmailMessage(
            message,
            myAliases: []
        )

        XCTAssertEqual(processed?.plainTextBody, "Let’s gooooi")
        XCTAssertEqual(processed?.cleanedSnippet, "Let’s gooooi")
    }

    func testProcessGmailMessage_snippetFallback_decodesHTMLEntities() async {
        let message = GmailMessage(
            id: "snippet-entity-fallback-message",
            threadId: "snippet-entity-fallback-thread",
            labelIds: ["INBOX"],
            snippet: "Tom &amp; Jerry says Let&#39;s go",
            historyId: "123",
            internalDate: "1704067200000",
            payload: MessagePart(
                partId: "0",
                mimeType: "text/plain",
                filename: nil,
                headers: baseHeaders(id: "snippet-entity-fallback-message"),
                body: nil,
                parts: nil
            ),
            sizeEstimate: 0
        )

        let processed = await processor.processGmailMessage(
            message,
            myAliases: []
        )

        XCTAssertNil(processed?.plainTextBody)
        XCTAssertEqual(processed?.cleanedSnippet, "Tom & Jerry says Let's go")
    }

    func testProcessGmailMessage_doesNotTreatHTMLBodyAsAttachment() async {
        let htmlBody = "<div>Body only</div>"
        let message = GmailMessage(
            id: "html-body-only-message",
            threadId: "html-body-only-thread",
            labelIds: ["INBOX"],
            snippet: "Body only",
            historyId: "123",
            internalDate: "1704067200000",
            payload: MessagePart(
                partId: "0",
                mimeType: "text/html",
                filename: nil,
                headers: baseHeaders(id: "html-body-only-message"),
                body: MessageBody(
                    size: htmlBody.count,
                    data: htmlBody.data(using: .utf8)?.base64EncodedString(),
                    attachmentId: nil
                ),
                parts: nil
            ),
            sizeEstimate: htmlBody.count
        )

        let processed = await processor.processGmailMessage(
            message,
            myAliases: []
        )

        XCTAssertEqual(processed?.attachmentInfo.count, 0)
        XCTAssertFalse(processed?.hasAttachments ?? true)
    }

    func testProcessGmailMessage_htmlOnlyMessage_derivesPlainTextBodyFromHTML() async {
        let htmlBody = """
        <html><body>
        <div>Hi Brynn and Kevin,</div>
        <div><br></div>
        <div>We are delighted to invite you to opening night.</div>
        <div>Please let me know if you'll be able to make it.</div>
        </body></html>
        """

        let message = GmailMessage(
            id: "html-only-derived-plain-text-message",
            threadId: "html-only-derived-plain-text-thread",
            labelIds: ["INBOX"],
            snippet: "Hi Brynn and Kevin, We are delighted to invite you...",
            historyId: "123",
            internalDate: "1704067200000",
            payload: MessagePart(
                partId: "0",
                mimeType: "text/html",
                filename: nil,
                headers: baseHeaders(id: "html-only-derived-plain-text-message"),
                body: MessageBody(
                    size: htmlBody.count,
                    data: htmlBody.data(using: .utf8)?.base64EncodedString(),
                    attachmentId: nil
                ),
                parts: nil
            ),
            sizeEstimate: htmlBody.count
        )

        let processed = await processor.processGmailMessage(
            message,
            myAliases: []
        )

        let plainTextBody = processed?.plainTextBody ?? ""
        XCTAssertTrue(plainTextBody.contains("Hi Brynn and Kevin,"))
        XCTAssertTrue(plainTextBody.contains("We are delighted to invite you to opening night."))
        XCTAssertTrue(plainTextBody.contains("Please let me know if you'll be able to make it."))
    }

    func testProcessGmailMessage_multipartAlternative_withParameterizedHTMLMime_extractsHTMLBody() async {
        let plainBody = "Fallback plain text body"
        let htmlBody = "<html><body><p>HTML_TOKEN_BILL_APPROVAL</p></body></html>"

        let message = GmailMessage(
            id: "multipart-parameterized-html-message",
            threadId: "multipart-parameterized-html-thread",
            labelIds: ["INBOX"],
            snippet: "HTML token",
            historyId: "123",
            internalDate: "1704067200000",
            payload: MessagePart(
                partId: "0",
                mimeType: "multipart/alternative",
                filename: nil,
                headers: baseHeaders(id: "multipart-parameterized-html-message"),
                body: nil,
                parts: [
                    MessagePart(
                        partId: "0.0",
                        mimeType: "text/plain",
                        filename: nil,
                        headers: nil,
                        body: MessageBody(
                            size: plainBody.count,
                            data: plainBody.data(using: .utf8)?.base64EncodedString(),
                            attachmentId: nil
                        ),
                        parts: nil
                    ),
                    MessagePart(
                        partId: "0.1",
                        mimeType: "Text/HTML; charset=utf-8",
                        filename: nil,
                        headers: nil,
                        body: MessageBody(
                            size: htmlBody.count,
                            data: htmlBody.data(using: .utf8)?.base64EncodedString(),
                            attachmentId: nil
                        ),
                        parts: nil
                    )
                ]
            ),
            sizeEstimate: htmlBody.count + plainBody.count
        )

        let processed = await processor.processGmailMessage(
            message,
            myAliases: []
        )

        XCTAssertEqual(processed?.plainTextBody, plainBody)
        XCTAssertTrue(processed?.htmlBody?.contains("HTML_TOKEN_BILL_APPROVAL") == true)
    }

    func testProcessGmailMessage_multipartAlternative_htmlPartWithMissingMimeType_usesContentTypeHeader() async {
        let plainBody = "Fallback plain text body"
        let htmlBody = "<html><body><p>HTML_TOKEN_FROM_HEADER_ONLY</p></body></html>"

        let message = GmailMessage(
            id: "multipart-header-only-html-message",
            threadId: "multipart-header-only-html-thread",
            labelIds: ["INBOX"],
            snippet: "HTML token",
            historyId: "123",
            internalDate: "1704067200000",
            payload: MessagePart(
                partId: "0",
                mimeType: "multipart/alternative",
                filename: nil,
                headers: baseHeaders(id: "multipart-header-only-html-message"),
                body: nil,
                parts: [
                    MessagePart(
                        partId: "0.0",
                        mimeType: "text/plain",
                        filename: nil,
                        headers: nil,
                        body: MessageBody(
                            size: plainBody.count,
                            data: plainBody.data(using: .utf8)?.base64EncodedString(),
                            attachmentId: nil
                        ),
                        parts: nil
                    ),
                    MessagePart(
                        partId: "0.1",
                        mimeType: nil,
                        filename: nil,
                        headers: [
                            MessageHeader(name: "Content-Type", value: "text/html; charset=utf-8"),
                            MessageHeader(name: "Content-Transfer-Encoding", value: "quoted-printable")
                        ],
                        body: MessageBody(
                            size: htmlBody.count,
                            data: htmlBody.data(using: .utf8)?.base64EncodedString(),
                            attachmentId: nil
                        ),
                        parts: nil
                    )
                ]
            ),
            sizeEstimate: htmlBody.count + plainBody.count
        )

        let processed = await processor.processGmailMessage(
            message,
            myAliases: []
        )

        XCTAssertEqual(processed?.plainTextBody, plainBody)
        XCTAssertTrue(processed?.htmlBody?.contains("HTML_TOKEN_FROM_HEADER_ONLY") == true)
    }

    func testProcessGmailMessage_textBodyContainingMimeOnlyRawSource_extractsEmbeddedHTML() async {
        let rawSource = """
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
          <h1>HTML_TOKEN_MIME_ONLY_PROCESSOR</h1>
          <p>Tickets are now on sale for the 2026 Film Festival</p>
        </body>
        </html>

        --newsletter-boundary-123--
        """

        let message = GmailMessage(
            id: "mime-only-raw-source-message",
            threadId: "mime-only-raw-source-thread",
            labelIds: ["INBOX"],
            snippet: "Tickets are now on sale",
            historyId: "123",
            internalDate: "1704067200000",
            payload: MessagePart(
                partId: "0",
                mimeType: "text/plain",
                filename: nil,
                headers: baseHeaders(id: "mime-only-raw-source-message"),
                body: MessageBody(
                    size: rawSource.count,
                    data: rawSource.data(using: .utf8)?.base64EncodedString(),
                    attachmentId: nil
                ),
                parts: nil
            ),
            sizeEstimate: rawSource.count
        )

        let processed = await processor.processGmailMessage(
            message,
            myAliases: []
        )

        XCTAssertTrue(processed?.htmlBody?.contains("HTML_TOKEN_MIME_ONLY_PROCESSOR") == true)
        XCTAssertTrue(processed?.plainTextBody?.contains("Example Museum") == true)
        XCTAssertTrue(processed?.plainTextBody?.contains("Tickets are now on sale for the 2026 Film Festival") == true)
        XCTAssertFalse(processed?.plainTextBody?.contains("Content-Type: multipart/alternative") == true)
    }

    func testProcessGmailMessage_collectsNormalizedInlineCIDPrefetchTargetsFromHTMLAndMIME() async throws {
        let html = """
        <html><body>
        <img src="cid:///%3CLogo%40Example.COM%3E" alt="Logo">
        </body></html>
        """

        let message = makeMultipartMessage(
            id: "inline-cid-prefetch-target-message",
            parts: [
                MessagePart(
                    partId: "0",
                    mimeType: "text/html",
                    filename: nil,
                    headers: [
                        MessageHeader(name: "Content-Type", value: "text/html; charset=utf-8")
                    ],
                    body: MessageBody(
                        size: html.count,
                        data: Data(html.utf8).base64EncodedString(),
                        attachmentId: nil
                    ),
                    parts: nil
                ),
                MessagePart(
                    partId: "1",
                    mimeType: "image/png",
                    filename: "logo.png",
                    headers: [
                        MessageHeader(name: "Content-Disposition", value: "inline; filename=\"logo.png\""),
                        MessageHeader(name: "Content-ID", value: "<Logo@Example.COM>")
                    ],
                    body: MessageBody(
                        size: 120,
                        data: nil,
                        attachmentId: "att-logo"
                    ),
                    parts: nil
                ),
                MessagePart(
                    partId: "2",
                    mimeType: "image/png",
                    filename: "mime-only.png",
                    headers: [
                        MessageHeader(name: "Content-Disposition", value: "inline; filename=\"mime-only.png\""),
                        MessageHeader(name: "Content-ID", value: "<Mime-Only@Example.COM>")
                    ],
                    body: MessageBody(
                        size: 90,
                        data: nil,
                        attachmentId: "att-mime-only"
                    ),
                    parts: nil
                )
            ]
        )

        let processedMessage = await processor.processGmailMessage(message, myAliases: [])
        let processed = try XCTUnwrap(processedMessage)

        XCTAssertEqual(
            processed.inlineCIDPrefetchContentIDs,
            ["logo@example.com", "mime-only@example.com"]
        )
        XCTAssertEqual(
            processed.inlineCIDPrefetchAttachmentIDs,
            ["att-logo", "att-mime-only"]
        )
    }

    func testProcessGmailMessage_collectsInlineCIDPrefetchTargetsFromMIMEWhenHTMLHasNoCIDReferences() async throws {
        let html = "<html><body><p>No inline image references here.</p></body></html>"
        let message = makeMultipartMessage(
            id: "inline-cid-prefetch-mime-only-message",
            parts: [
                MessagePart(
                    partId: "0",
                    mimeType: "text/html",
                    filename: nil,
                    headers: [
                        MessageHeader(name: "Content-Type", value: "text/html; charset=utf-8")
                    ],
                    body: MessageBody(
                        size: html.count,
                        data: Data(html.utf8).base64EncodedString(),
                        attachmentId: nil
                    ),
                    parts: nil
                ),
                MessagePart(
                    partId: "1",
                    mimeType: "image/png",
                    filename: "mime-only.png",
                    headers: [
                        MessageHeader(name: "Content-Disposition", value: "inline; filename=\"mime-only.png\""),
                        MessageHeader(name: "Content-ID", value: "<Mime-Only@Example.COM>")
                    ],
                    body: MessageBody(
                        size: 90,
                        data: nil,
                        attachmentId: "att-mime-only"
                    ),
                    parts: nil
                )
            ]
        )

        let processedMessage = await processor.processGmailMessage(message, myAliases: [])
        let processed = try XCTUnwrap(processedMessage)

        XCTAssertEqual(processed.inlineCIDPrefetchContentIDs, ["mime-only@example.com"])
        XCTAssertEqual(processed.inlineCIDPrefetchAttachmentIDs, ["att-mime-only"])
    }

    private func makeMultipartMessage(id: String, parts: [MessagePart]) -> GmailMessage {
        GmailMessage(
            id: id,
            threadId: "\(id)-thread",
            labelIds: ["INBOX"],
            snippet: "snippet",
            historyId: "123",
            internalDate: "1704067200000",
            payload: MessagePart(
                partId: "",
                mimeType: "multipart/mixed",
                filename: nil,
                headers: baseHeaders(id: id),
                body: nil,
                parts: parts
            ),
            sizeEstimate: 1024
        )
    }

    private func baseHeaders(id: String) -> [MessageHeader] {
        [
            MessageHeader(name: "Subject", value: "Attachment test"),
            MessageHeader(name: "From", value: "Sender <sender@example.com>"),
            MessageHeader(name: "To", value: "recipient@example.com"),
            MessageHeader(name: "Message-ID", value: "<\(id)@test.example.com>")
        ]
    }
}

private func makeMultipartAlternativeMessage(
    id: String,
    plainText: String,
    html: String,
    plainFirst: Bool
) -> GmailMessage {
    let plainPart = MessagePart(
        partId: "0.0",
        mimeType: "text/plain",
        filename: nil,
        headers: [
            MessageHeader(name: "Content-Type", value: "text/plain; charset=utf-8")
        ],
        body: MessageBody(
            size: plainText.count,
            data: plainText.data(using: .utf8)?.base64EncodedString(),
            attachmentId: nil
        ),
        parts: nil
    )
    let htmlPart = MessagePart(
        partId: "0.1",
        mimeType: "text/html",
        filename: nil,
        headers: [
            MessageHeader(name: "Content-Type", value: "text/html; charset=utf-8")
        ],
        body: MessageBody(
            size: html.count,
            data: html.data(using: .utf8)?.base64EncodedString(),
            attachmentId: nil
        ),
        parts: nil
    )
    let parts = plainFirst ? [plainPart, htmlPart] : [htmlPart, plainPart]

    return GmailMessage(
        id: id,
        threadId: "\(id)-thread",
        labelIds: ["INBOX"],
        snippet: "Book now",
        historyId: "12345",
        internalDate: "1704067200000",
        payload: MessagePart(
            partId: "0",
            mimeType: "multipart/alternative",
            filename: nil,
            headers: [
                MessageHeader(name: "Subject", value: "Reservation offer"),
                MessageHeader(name: "From", value: "Reservations <reservations@example.com>"),
                MessageHeader(name: "To", value: "person@example.com")
            ],
            body: nil,
            parts: parts
        ),
        sizeEstimate: html.count + plainText.count
    )
}

final class GoldenCorpusReplayTests: XCTestCase {
    private var processor: MessageProcessor!

    override func setUp() {
        super.setUp()
        processor = MessageProcessor()
    }

    override func tearDown() {
        processor = nil
        super.tearDown()
    }

    func testGoldenCorpusReplay() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.plainTextQuoteCleanupCases {
            XCTContext.runActivity(named: "plainText:\(scenario.id)") { _ in
                let result = ChatBubbleTextProcessor.process(
                    content: scenario.input,
                    options: ChatBubbleTextProcessorOptions(
                        inputKind: .plainText,
                        sanitizeRawEmailSource: true,
                        decodeHTMLEntities: true,
                        formatSignOffLineBreaks: true,
                        classifyRichContent: false
                    )
                )
                let actual = result.mainText ?? ""
                XCTAssertEqual(
                    normalize(actual),
                    normalize(scenario.expected),
                    scenario.notes ?? "Plain-text quote cleanup mismatch for scenario \(scenario.id)"
                )
            }
        }

        for scenario in corpus.htmlToBubbleTextCases {
            XCTContext.runActivity(named: "htmlToText:\(scenario.id)") { _ in
                let result = ChatBubbleTextProcessor.process(
                    content: scenario.inputHTML,
                    options: ChatBubbleTextProcessorOptions(
                        inputKind: .html,
                        sanitizeRawEmailSource: false,
                        decodeHTMLEntities: true,
                        formatSignOffLineBreaks: true,
                        classifyRichContent: false
                    )
                )
                let formatted = result.mainText ?? ""

                XCTAssertEqual(
                    normalize(formatted),
                    normalize(scenario.expected),
                    scenario.notes ?? "HTML-to-bubble text mismatch for scenario \(scenario.id)"
                )
            }
        }

        for scenario in corpus.rawSourceHTMLRecoveryCases {
            XCTContext.runActivity(named: "rawSourceHTML:\(scenario.id)") { _ in
                let extractedHTML = RawEmailSourceSanitizer.extractHTMLText(from: scenario.input)
                XCTAssertNotNil(
                    extractedHTML,
                    scenario.notes ?? "Expected embedded HTML for scenario \(scenario.id)"
                )

                let html = extractedHTML ?? ""
                XCTAssertTrue(
                    normalize(html).contains(normalize(scenario.expectedHTMLContains)),
                    scenario.notes ?? "Raw-source HTML extraction mismatch for scenario \(scenario.id)"
                )

                let result = ChatBubbleTextProcessor.process(
                    content: html,
                    options: ChatBubbleTextProcessorOptions(
                        inputKind: .html,
                        sanitizeRawEmailSource: false,
                        decodeHTMLEntities: true,
                        formatSignOffLineBreaks: true,
                        classifyRichContent: true
                    )
                )

                XCTAssertEqual(
                    result.hasRichContent,
                    scenario.expectedHasRichHTMLContent,
                    scenario.notes ?? "Raw-source HTML rich-content mismatch for scenario \(scenario.id)"
                )

                XCTAssertTrue(
                    normalize(result.mainText ?? "").contains(normalize(scenario.expectedTextContains)),
                    scenario.notes ?? "Raw-source HTML text extraction mismatch for scenario \(scenario.id)"
                )
            }
        }

        for scenario in corpus.richHTMLDetectionCases {
            XCTContext.runActivity(named: "richHTML:\(scenario.id)") { _ in
                let handler = HTMLContentHandler.shared
                let messageId = "golden-rich-\(scenario.id)-\(UUID().uuidString)"
                _ = handler.saveHTML(scenario.inputHTML, for: messageId)
                defer { handler.deleteHTML(for: messageId) }

                let result = ProcessedTextCache.processMessage(messageId: messageId, handler: handler)

                XCTAssertEqual(
                    result.hasRichContent,
                    scenario.expectedHasRichHTMLContent,
                    scenario.notes ?? "Rich HTML detection mismatch for scenario \(scenario.id)"
                )
            }
        }

        for scenario in corpus.displayPolicyCases {
            XCTContext.runActivity(named: "displayPolicy:\(scenario.id)") { _ in
                let shouldShowPreview = MessageDisplayPolicy.shouldShowHTMLPreview(
                    hasHTMLSource: scenario.hasHTMLSource,
                    isForwardedEmail: scenario.isForwardedEmail,
                    isNewsletter: scenario.isNewsletter,
                    hasRichHTMLContent: scenario.hasRichHTMLContent,
                    isFromMe: scenario.isFromMe,
                    isOneToOneConversation: scenario.isOneToOneConversation,
                    subject: scenario.subject,
                    senderEmail: scenario.senderEmail
                )

                XCTAssertEqual(
                    shouldShowPreview,
                    scenario.expectedShowHTMLPreview,
                    scenario.notes ?? "Display policy mismatch for scenario \(scenario.id)"
                )
            }
        }

        for scenario in corpus.conversationListSnippetCases {
            XCTContext.runActivity(named: "conversationListSnippet:\(scenario.id)") { _ in
                let testStack = TestCoreDataStack()
                let context = testStack.viewContext

                let conversationBuilder = ConversationBuilder()
                    .withLastMessageDate(Date())
                let conversation = scenario.conversationSnippet.map {
                    conversationBuilder.withSnippet($0).build(in: context)
                } ?? conversationBuilder.build(in: context)

                if scenario.latestMessageSnippet != nil || scenario.latestMessageCleanedSnippet != nil {
                    let message = MessageBuilder()
                        .withId("golden-conversation-snippet-\(scenario.id)")
                        .withDate(Date())
                        .inConversation(conversation)
                        .build(in: context)
                    message.snippet = scenario.latestMessageSnippet
                    message.cleanedSnippet = scenario.latestMessageCleanedSnippet
                }

                let snapshot = ConversationSnapshot(from: conversation)

                XCTAssertEqual(
                    snapshot.snippet,
                    scenario.expected,
                    scenario.notes ?? "Conversation list snippet mismatch for scenario \(scenario.id)"
                )
            }
        }

        for scenario in corpus.newsletterDetectionCases {
            XCTContext.runActivity(named: "newsletter:\(scenario.id)") { _ in
                var headers = ProcessedHeaders()
                headers.from = scenario.from
                headers.replyTo = scenario.replyTo
                headers.subject = scenario.subject
                headers.listUnsubscribe = scenario.listUnsubscribe
                headers.listUnsubscribePost = scenario.listUnsubscribePost
                headers.listId = scenario.listId
                headers.precedence = scenario.precedence
                headers.to = (0..<scenario.toCount).map { EmailAddress(email: "to\($0)@example.com", displayName: nil) }
                headers.cc = (0..<scenario.ccCount).map { EmailAddress(email: "cc\($0)@example.com", displayName: nil) }

                let result = processor.calculateNewsletterScore(
                    labelIds: scenario.labelIds,
                    headers: headers
                )

                XCTAssertEqual(
                    result.isNewsletter,
                    scenario.expectedIsNewsletter,
                    scenario.notes ?? "Newsletter classification mismatch for scenario \(scenario.id)"
                )

                if let expectedScore = scenario.expectedScore {
                    XCTAssertEqual(
                        result.score,
                        expectedScore,
                        scenario.notes ?? "Newsletter score mismatch for scenario \(scenario.id)"
                    )
                }
            }
        }
    }

    // MARK: - Corpus Loading

    private func loadCorpus() throws -> GoldenCorpus {
        // Load from the test bundle, not `#filePath`: the compile-time source path is unreachable
        // from sandboxed simulator test processes, where it resolves to a host checkout path the
        // simulator can't read. The fixture is bundled as a test resource.
        let bundle = Bundle(for: type(of: self))
        guard let fixtureURL = bundle.url(forResource: "golden_message_corpus", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }

        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        return try decoder.decode(GoldenCorpus.self, from: data)
    }

    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct GoldenCorpus: Decodable {
    let plainTextQuoteCleanupCases: [PlainTextQuoteCleanupCase]
    let htmlToBubbleTextCases: [HTMLToBubbleTextCase]
    let rawSourceHTMLRecoveryCases: [RawSourceHTMLRecoveryCase]
    let richHTMLDetectionCases: [RichHTMLDetectionCase]
    let displayPolicyCases: [DisplayPolicyCase]
    let conversationListSnippetCases: [ConversationListSnippetCase]
    let newsletterDetectionCases: [NewsletterDetectionCase]

    enum CodingKeys: String, CodingKey {
        case plainTextQuoteCleanupCases
        case htmlToBubbleTextCases
        case rawSourceHTMLRecoveryCases
        case richHTMLDetectionCases
        case displayPolicyCases
        case conversationListSnippetCases
        case newsletterDetectionCases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plainTextQuoteCleanupCases = try container.decodeIfPresent([PlainTextQuoteCleanupCase].self, forKey: .plainTextQuoteCleanupCases) ?? []
        htmlToBubbleTextCases = try container.decodeIfPresent([HTMLToBubbleTextCase].self, forKey: .htmlToBubbleTextCases) ?? []
        rawSourceHTMLRecoveryCases = try container.decodeIfPresent([RawSourceHTMLRecoveryCase].self, forKey: .rawSourceHTMLRecoveryCases) ?? []
        richHTMLDetectionCases = try container.decodeIfPresent([RichHTMLDetectionCase].self, forKey: .richHTMLDetectionCases) ?? []
        displayPolicyCases = try container.decodeIfPresent([DisplayPolicyCase].self, forKey: .displayPolicyCases) ?? []
        conversationListSnippetCases = try container.decodeIfPresent([ConversationListSnippetCase].self, forKey: .conversationListSnippetCases) ?? []
        newsletterDetectionCases = try container.decodeIfPresent([NewsletterDetectionCase].self, forKey: .newsletterDetectionCases) ?? []
    }
}

private struct PlainTextQuoteCleanupCase: Decodable {
    let id: String
    let input: String
    let expected: String
    let notes: String?
}

private struct HTMLToBubbleTextCase: Decodable {
    let id: String
    let inputHTML: String
    let expected: String
    let notes: String?
}

private struct RawSourceHTMLRecoveryCase: Decodable {
    let id: String
    let input: String
    let expectedHTMLContains: String
    let expectedTextContains: String
    let expectedHasRichHTMLContent: Bool
    let notes: String?
}

private struct RichHTMLDetectionCase: Decodable {
    let id: String
    let inputHTML: String
    let expectedHasRichHTMLContent: Bool
    let notes: String?
}

private struct DisplayPolicyCase: Decodable {
    let id: String
    let hasHTMLSource: Bool
    let isForwardedEmail: Bool
    let isNewsletter: Bool
    let hasRichHTMLContent: Bool
    let isFromMe: Bool
    let isOneToOneConversation: Bool
    let subject: String?
    let senderEmail: String?
    let expectedShowHTMLPreview: Bool
    let notes: String?
}

private struct ConversationListSnippetCase: Decodable {
    let id: String
    let conversationSnippet: String?
    let latestMessageSnippet: String?
    let latestMessageCleanedSnippet: String?
    let expected: String?
    let notes: String?
}

private struct NewsletterDetectionCase: Decodable {
    let id: String
    let labelIds: [String]
    let from: String?
    let replyTo: String?
    let subject: String?
    let listUnsubscribe: String?
    let listUnsubscribePost: String?
    let listId: String?
    let precedence: String?
    let toCount: Int
    let ccCount: Int
    let expectedIsNewsletter: Bool
    let expectedScore: Int?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case labelIds
        case from
        case replyTo
        case subject
        case listUnsubscribe
        case listUnsubscribePost
        case listId
        case precedence
        case toCount
        case ccCount
        case expectedIsNewsletter
        case expectedScore
        case notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        labelIds = try container.decodeIfPresent([String].self, forKey: .labelIds) ?? []
        from = try container.decodeIfPresent(String.self, forKey: .from)
        replyTo = try container.decodeIfPresent(String.self, forKey: .replyTo)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        listUnsubscribe = try container.decodeIfPresent(String.self, forKey: .listUnsubscribe)
        listUnsubscribePost = try container.decodeIfPresent(String.self, forKey: .listUnsubscribePost)
        listId = try container.decodeIfPresent(String.self, forKey: .listId)
        precedence = try container.decodeIfPresent(String.self, forKey: .precedence)
        toCount = try container.decodeIfPresent(Int.self, forKey: .toCount) ?? 0
        ccCount = try container.decodeIfPresent(Int.self, forKey: .ccCount) ?? 0
        expectedIsNewsletter = try container.decode(Bool.self, forKey: .expectedIsNewsletter)
        expectedScore = try container.decodeIfPresent(Int.self, forKey: .expectedScore)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}
