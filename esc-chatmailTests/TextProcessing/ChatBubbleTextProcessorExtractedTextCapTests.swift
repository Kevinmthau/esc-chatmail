import XCTest
@testable import esc_chatmail

/// Bubble derivation reads at most `ChatBubbleTextProcessor
/// .extractedTextUTF16Limit` of a body's extracted text, cut at a line break.
/// Revert-check: the `cappedExtractedText` calls in `processPlainText` and
/// `extractPlainTextFromHTML`; without them the sentinel past the cap is in
/// the derived text and the outputs differ.
final class ChatBubbleTextProcessorExtractedTextCapTests: XCTestCase {
    private static let sentinel = "SENTINEL-PAST-THE-CAP"

    /// About a megabyte of log lines, each a sentence, then the sentinel.
    private static func logBody(lineCount: Int = 24_000) -> String {
        (0..<lineCount).map { "Line \($0): backup of volume \($0 % 7) finished in \($0 % 60) seconds." }
            .joined(separator: "\n") + "\n" + sentinel
    }

    func testCappedExtractedText_underTheLimit_isUnchanged() {
        let text = "short\ntext"
        XCTAssertEqual(ChatBubbleTextProcessor.cappedExtractedText(text), text)
        let exact = String(repeating: "a", count: ChatBubbleTextProcessor.extractedTextUTF16Limit)
        XCTAssertEqual(ChatBubbleTextProcessor.cappedExtractedText(exact), exact)
    }

    func testCappedExtractedText_overTheLimit_cutsAtTheLastLineBreak() {
        let limit = ChatBubbleTextProcessor.extractedTextUTF16Limit
        let firstLine = String(repeating: "a", count: limit - 10)
        let text = firstLine + "\nbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        XCTAssertEqual(ChatBubbleTextProcessor.cappedExtractedText(text), firstLine)
    }

    func testCappedExtractedText_withoutALineBreak_cutsOnACharacterBoundary() {
        let limit = ChatBubbleTextProcessor.extractedTextUTF16Limit
        // An emoji (two UTF-16 units) straddles the limit.
        let text = String(repeating: "a", count: limit - 1) + "😀" + "tail"
        let capped = ChatBubbleTextProcessor.cappedExtractedText(text)
        XCTAssertEqual(capped, String(repeating: "a", count: limit - 1))
        XCTAssertLessThanOrEqual(capped.utf16.count, limit)
    }

    func testPlainTextDerivation_megabyteBody_equalsTheDerivationOfItsCappedPrefix() {
        let body = Self.logBody()
        XCTAssertGreaterThan(body.utf16.count, 1_000_000)
        let prefix = ChatBubbleTextProcessor.cappedExtractedText(body)

        let derived = ChatBubbleTextProcessor.plainTextOnlyFallback(from: body).mainText
        XCTAssertEqual(derived, ChatBubbleTextProcessor.plainTextOnlyFallback(from: prefix).mainText)
        XCTAssertEqual(derived.map { $0.contains(Self.sentinel) }, false)
        XCTAssertEqual(derived.map { $0.contains("Line 20000:") }, false)
        XCTAssertEqual(derived.map { $0.contains("Line 0:") }, true)
    }

    func testHTMLDerivation_megabyteBody_equalsTheDerivationOfItsCappedPrefix() {
        let lines = Self.logBody().components(separatedBy: "\n")
        let html = "<html><body>" + lines.map { "<div>\($0)</div>" }.joined() + "</body></html>"
        let extracted = TextProcessing.extractPlainText(from: html)
        XCTAssertGreaterThan(extracted.utf16.count, ChatBubbleTextProcessor.extractedTextUTF16Limit)

        let derived = ChatBubbleTextProcessor.htmlCompatibilityFallback(from: html, classifyRichContent: false).mainText
        XCTAssertEqual(derived.map { $0.contains(Self.sentinel) }, false)
        XCTAssertEqual(derived.map { $0.contains("Line 20000:") }, false)
        XCTAssertEqual(derived.map { $0.contains("Line 0:") }, true)
    }

    /// Ingest derives the stored preview through the same function, so the
    /// cap reaches it too; the stored snippet is not capped
    /// (`docs/scalability-review.md`, `list-search-contains-uncapped-snippet`).
    func testIngestPreview_megabyteHTML_omitsTextPastTheCap() {
        let lines = Self.logBody().components(separatedBy: "\n")
        let html = "<html><body>" + lines.map { "<p>\($0)</p>" }.joined() + "</body></html>"
        let preview = MessageProcessor.deriveHTMLChatPreview(from: html)
        XCTAssertEqual(preview.map { $0.contains(Self.sentinel) }, false)
        XCTAssertEqual(preview.map { $0.contains("Line 20000:") }, false)
        XCTAssertEqual(preview.map { $0.contains("Line 0:") }, true)
    }
}
