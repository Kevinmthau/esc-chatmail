import XCTest
@testable import esc_chatmail

final class RepeatedCorporateSignatureTests: XCTestCase {
    private typealias Fixture = RepeatedCorporateSignatureFixture

    func testOutlookHTML_repeatedCorporateFooterLeavesReplyAndSignOff() {
        let result = htmlPreview(Fixture.html())

        XCTAssertEqual(normalized(result.mainText), normalized(Fixture.expectedChatText))
        XCTAssertFalse(result.hasRichContent)
        XCTAssertTrue(result.quotedParts.isEmpty)
    }

    func testPlainText_repeatedCorporateFooterLeavesReplyAndSignOff() {
        let result = plainPreview(Fixture.plainText())

        XCTAssertEqual(normalized(result.mainText), normalized(Fixture.expectedChatText))
        XCTAssertFalse(result.hasRichContent)
        XCTAssertFalse(result.mainText?.contains(Fixture.priorReply) ?? true)
    }

    func testUnknownRepeatedBoilerplate_isRemovedWithoutIndustrySpecificPhrases() {
        let results = [
            htmlPreview(Fixture.html(footer: .operations)),
            plainPreview(Fixture.plainText(footer: .operations))
        ]

        for result in results {
            XCTAssertEqual(normalized(result.mainText), normalized(Fixture.expectedChatText))
        }
    }

    func testNewPostscriptAfterRepeatedFooter_isPreserved() {
        let results = [
            htmlPreview(Fixture.html(currentPostscript: Fixture.newPostscript)),
            plainPreview(Fixture.plainText(currentPostscript: Fixture.newPostscript))
        ]

        for result in results {
            XCTAssertTrue(result.mainText?.contains(Fixture.newPostscript) ?? false)
            XCTAssertTrue(result.mainText?.contains(Fixture.bodyParagraphs[1]) ?? false)
            XCTAssertFalse(result.mainText?.contains(Fixture.priorReply) ?? true)
        }
    }

    func testChangedPostscriptAfterRepeatedFooter_preservesCurrentVersion() {
        let results = [
            htmlPreview(Fixture.html(
                currentPostscript: Fixture.newPostscript,
                historicalPostscript: Fixture.oldPostscript
            )),
            plainPreview(Fixture.plainText(
                currentPostscript: Fixture.newPostscript,
                historicalPostscript: Fixture.oldPostscript
            ))
        ]

        for result in results {
            XCTAssertTrue(result.mainText?.contains(Fixture.newPostscript) ?? false)
            XCTAssertFalse(result.mainText?.contains(Fixture.oldPostscript) ?? true)
        }
    }

    func testUnknownFooterWithoutHistoricalMatch_isPreserved() {
        let footer = Fixture.footerParagraphs(.operations)
        let results = [
            htmlPreview(Fixture.html(footer: .operations, includeHistory: false)),
            plainPreview(Fixture.plainText(footer: .operations, includeHistory: false))
        ]

        for result in results {
            for paragraph in footer {
                XCTAssertTrue(normalized(result.mainText).contains(normalized(paragraph)))
            }
        }
    }

    func testDifferentHistoricalFooter_doesNotAuthorizeRemovingCurrentProse() {
        let results = [
            htmlPreview(Fixture.html(footer: .operations, historicalFooter: .coverage)),
            plainPreview(Fixture.plainText(footer: .operations, historicalFooter: .coverage))
        ]

        for result in results {
            for paragraph in Fixture.footerParagraphs(.operations) {
                XCTAssertTrue(normalized(result.mainText).contains(normalized(paragraph)))
            }
            XCTAssertFalse(result.mainText?.contains(Fixture.priorReply) ?? true)
        }
    }

    func testQuoteOnlyHTMLCleanup_keepsCurrentSignatureAndFooter() throws {
        let cleaned = try XCTUnwrap(HTMLQuoteRemover.removeQuotes(from: Fixture.html(), mode: .quotedOnly))
        let visibleText = normalized(TextProcessing.extractPlainText(from: cleaned))

        XCTAssertTrue(visibleText.contains(Fixture.contactLines[0]))
        for paragraph in Fixture.footerParagraphs(.coverage) {
            XCTAssertTrue(visibleText.contains(normalized(paragraph)))
        }
        XCTAssertFalse(visibleText.contains(Fixture.priorReply))
    }

    func testStoredHTMLPreview_doesNotMutateFullMessageSource() throws {
        let messageID = "repeated-signature-source-\(UUID().uuidString)"
        let handler = HTMLContentHandler.shared
        defer { handler.deleteHTML(for: messageID) }
        let html = Fixture.html()
        XCTAssertNotNil(handler.saveHTML(html, for: messageID))

        let preview = ProcessedTextCache.processMessage(messageId: messageID, handler: handler)

        XCTAssertEqual(normalized(preview.plainText), normalized(Fixture.expectedChatText))
        XCTAssertEqual(try XCTUnwrap(handler.loadHTML(for: messageID)), html)
    }

    private func htmlPreview(_ html: String) -> ChatBubbleTextProcessingResult {
        ChatBubbleTextProcessor.htmlCompatibilityFallback(from: html, classifyRichContent: true)
    }

    func testRepeatedPostscript_remainsAuthoredContent() {
        let results = [
            htmlPreview(Fixture.html(currentPostscript: Fixture.newPostscript, historicalPostscript: Fixture.newPostscript)),
            plainPreview(Fixture.plainText(currentPostscript: Fixture.newPostscript, historicalPostscript: Fixture.newPostscript))
        ]
        for result in results {
            XCTAssertTrue(result.mainText?.contains(Fixture.newPostscript) ?? false)
        }
    }

    func testAuthoredSignatureTemplate_isPreservedEvenWhenRepeatedInHistory() {
        let text = """
        Please review this signature template:
        Sincerely,
        Jane Doe
        Account Manager
        jane@example.test
        202-555-0101
        These terms remain under review.
        """
        XCTAssertEqual(RepeatedSignatureRemover.removeSignature(from: text, quotedText: { text }), text)
    }

    func testContactEvidenceAfterAuthoredProse_doesNotEstablishSignature() {
        let text = """
        Here is the proposed draft.
        Sincerely,
        Jane Doe
        Account Manager
        Please contact the reviewers using these details.
        jane@example.test
        202-555-0101
        These terms remain under review.
        """
        XCTAssertEqual(RepeatedSignatureRemover.removeSignature(from: text, quotedText: { text }), text)
    }

    func testOrdinaryMessage_doesNotLoadQuotedSource() {
        let text = "Here is the update.\n\nPlease call when you are ready."
        XCTAssertEqual(RepeatedSignatureRemover.removeSignature(from: text) {
            XCTFail("Ordinary messages should not trigger another source projection")
            return ""
        }, text)
    }

    func testRepeatedDirectoryWithoutClosing_isPreserved() {
        let text = """
        Here are the contacts.
        Jane Doe
        Account Manager
        jane@example.test
        202-555-0101
        These terms remain under review.
        """
        XCTAssertEqual(RepeatedSignatureRemover.removeSignature(from: text, quotedText: { text }), text)
    }

    private func plainPreview(_ text: String) -> ChatBubbleTextProcessingResult {
        ChatBubbleTextProcessor.plainTextOnlyFallback(from: text)
    }

    private func normalized(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
