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

    // MARK: - Attachment Extraction

    func testProcessGmailMessage_extractsInlineDataAttachmentWithoutAttachmentId() async throws {
        let testStack = TestCoreDataStack()
        let context = testStack.viewContext

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
            myAliases: [],
            in: context
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
        let testStack = TestCoreDataStack()
        let context = testStack.viewContext

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
            myAliases: [],
            in: context
        )

        let attachment = try XCTUnwrap(processed?.attachmentInfo.first)
        XCTAssertEqual(processed?.attachmentInfo.count, 1)
        XCTAssertTrue(processed?.hasAttachments == true)
        XCTAssertEqual(attachment.filename, "attachment.png")
        XCTAssertEqual(attachment.contentId, "cid-without-filename")
        XCTAssertEqual(attachment.inlineData, inlineImageData)
    }

    func testProcessGmailMessage_doesNotTreatHTMLBodyAsAttachment() async {
        let testStack = TestCoreDataStack()
        let context = testStack.viewContext

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
            myAliases: [],
            in: context
        )

        XCTAssertEqual(processed?.attachmentInfo.count, 0)
        XCTAssertFalse(processed?.hasAttachments ?? true)
    }

    func testProcessGmailMessage_htmlOnlyMessage_derivesPlainTextBodyFromHTML() async {
        let testStack = TestCoreDataStack()
        let context = testStack.viewContext

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
            myAliases: [],
            in: context
        )

        let plainTextBody = processed?.plainTextBody ?? ""
        XCTAssertTrue(plainTextBody.contains("Hi Brynn and Kevin,"))
        XCTAssertTrue(plainTextBody.contains("We are delighted to invite you to opening night."))
        XCTAssertTrue(plainTextBody.contains("Please let me know if you'll be able to make it."))
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
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("TestSupport")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("golden_message_corpus.json")

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
    let richHTMLDetectionCases: [RichHTMLDetectionCase]
    let displayPolicyCases: [DisplayPolicyCase]
    let conversationListSnippetCases: [ConversationListSnippetCase]
    let newsletterDetectionCases: [NewsletterDetectionCase]

    enum CodingKeys: String, CodingKey {
        case plainTextQuoteCleanupCases
        case htmlToBubbleTextCases
        case richHTMLDetectionCases
        case displayPolicyCases
        case conversationListSnippetCases
        case newsletterDetectionCases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plainTextQuoteCleanupCases = try container.decodeIfPresent([PlainTextQuoteCleanupCase].self, forKey: .plainTextQuoteCleanupCases) ?? []
        htmlToBubbleTextCases = try container.decodeIfPresent([HTMLToBubbleTextCase].self, forKey: .htmlToBubbleTextCases) ?? []
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
        listId = try container.decodeIfPresent(String.self, forKey: .listId)
        precedence = try container.decodeIfPresent(String.self, forKey: .precedence)
        toCount = try container.decodeIfPresent(Int.self, forKey: .toCount) ?? 0
        ccCount = try container.decodeIfPresent(Int.self, forKey: .ccCount) ?? 0
        expectedIsNewsletter = try container.decode(Bool.self, forKey: .expectedIsNewsletter)
        expectedScore = try container.decodeIfPresent(Int.self, forKey: .expectedScore)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}
