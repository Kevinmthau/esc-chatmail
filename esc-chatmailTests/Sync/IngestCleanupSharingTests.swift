import XCTest
@testable import esc_chatmail

/// Ingest derives the chat preview and the rich-content pre-run from one
/// cleanup of the HTML it stores (`ProcessedMessage.storedHTML`, the trimmed
/// part), where it used to derive the preview from the untrimmed part and run
/// the cleanup again for the pre-run. That changes no stored preview only if
/// the surrounding whitespace never changes a derivation.
final class IngestCleanupSharingTests: XCTestCase {

    /// MIME parts arrive with line breaks and spaces around the HTML; the
    /// stored string is trimmed. Every golden-corpus HTML input must derive
    /// the same preview, exactly, and the same verdict either way.
    func testGoldenCorpusHTML_derivesTheSamePaddedAndTrimmed() throws {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "golden_message_corpus", withExtension: "json"))
        let corpus = try JSONDecoder().decode(SharingCorpus.self, from: Data(contentsOf: url))
        let inputs = corpus.htmlToBubbleTextCases.map(\.inputHTML)
            + corpus.richHTMLDetectionCases.map(\.inputHTML)
            + corpus.rawSourceHTMLRecoveryCases.map(\.input)
            + corpus.cleanedSnippetCases.compactMap(\.html)
        XCTAssertGreaterThan(inputs.count, 100)
        let paddings = [("\r\n", "\r\n"), ("\n\n  ", "\n \r\n\r\n"), ("\t ", ""), ("", "\n")]
        for html in inputs {
            let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedPreview = MessageProcessor.deriveHTMLChatPreview(from: trimmed)
            let expectedRich = RichContentClassifier.hasGenuineRichContentAfterCleanup(trimmed)
            for (before, after) in paddings {
                let padded = before + trimmed + after
                XCTAssertEqual(MessageProcessor.deriveHTMLChatPreview(from: padded), expectedPreview, String(html.prefix(120)).debugDescription)
                XCTAssertEqual(RichContentClassifier.hasGenuineRichContentAfterCleanup(padded), expectedRich, String(html.prefix(120)).debugDescription)
            }
        }
    }

    private static let richHTML = """
        <html><body><section><table role="presentation" width="100%">
        <tr><td><h1>Statement ready</h1></td></tr>
        <tr><td><p>Your monthly account statement is now available.</p></td></tr>
        <tr><td><a href="https://example.com/review">Review statement</a></td></tr>
        </table></section></body></html>
        """

    /// Revert-check: the `richContentPrerun` assignment in
    /// `MessageProcessor.processGmailMessage` (the processor then returns none).
    func testProcessGmailMessage_derivesPreviewAndPrerunFromTheStoredHTML() async throws {
        for html in [Self.richHTML, "<div>See you at noon.</div><div>Thanks,<br>Alex</div>"] {
            let message = Self.message(id: "shared", html: "\r\n\r\n  " + html + "\n \r\n")
            let result = try await MessageProcessor().processGmailMessage(message, myAliases: [])
            let processed = try XCTUnwrap(result)
            let stored = try XCTUnwrap(processed.storedHTML)
            XCTAssertEqual(stored, html)
            XCTAssertEqual(processed.richContentPrerun, RichContentPrerun(
                html: stored,
                isRich: RichContentClassifier.hasGenuineRichContentAfterCleanup(stored)
            ))
            XCTAssertEqual(processed.chatPreviewText, MessageProcessor.deriveHTMLChatPreview(from: stored))
        }
    }

    func testProcessGmailMessage_ownMessage_hasNoPrerun() async throws {
        let message = Self.message(id: "own", html: Self.richHTML, from: "me@example.com")
        let result = try await MessageProcessor().processGmailMessage(message, myAliases: ["me@example.com"])
        let processed = try XCTUnwrap(result)
        XCTAssertTrue(processed.headers.isFromMe)
        XCTAssertNil(processed.richContentPrerun)
    }

    /// The persister keeps a pre-run for the exact string it saves, and runs
    /// the classifier only for one it does not have. The kept answer here
    /// deliberately disagrees with the classifier, so a recomputation shows.
    /// Revert-check: the kept-pre-run branch in `MessagePersister.prepareMessage`
    /// (the first case then reads the classifier's `false`).
    func testPrepareMessage_keepsTheProcessorsPrerun_onlyForTheStoredString() async throws {
        let html = "<div>See you at noon.</div>"
        XCTAssertFalse(RichContentClassifier.hasGenuineRichContentAfterCleanup(html))
        for (prerunHTML, expectedIsRich) in [(html, true), (html + " ", false)] {
            var processed = ProcessedMessage()
            processed.id = "kept"
            processed.htmlBody = html
            processed.richContentPrerun = RichContentPrerun(html: prerunHTML, isRich: true)
            let persister = MessagePersister(
                messageProcessor: FixedMessageProcessor(processedMessage: processed),
                photoPrefetcher: { _ in },
                inlineCIDPrefetchScheduler: { _, _ in }
            )
            let prepared = try await persister.prepareMessage(Self.message(id: "kept", html: html), myAliases: [])
            guard case .processed(let result) = prepared else {
                return XCTFail("\(prepared)")
            }
            XCTAssertEqual(result.richContentPrerun, RichContentPrerun(html: html, isRich: expectedIsRich), prerunHTML)
        }
    }

    private static func message(id: String, html: String, from: String = "sender@example.com") -> GmailMessage {
        GmailMessage(
            id: id,
            threadId: "t-\(id)",
            labelIds: ["INBOX"],
            snippet: "snippet",
            historyId: "1",
            internalDate: "1704067200000",
            payload: MessagePart(
                partId: "",
                mimeType: "text/html",
                filename: nil,
                headers: [
                    MessageHeader(name: "From", value: "Sender <\(from)>"),
                    MessageHeader(name: "Content-Type", value: "text/html; charset=utf-8"),
                ],
                body: MessageBody(size: html.utf8.count, data: Data(html.utf8).base64EncodedString(), attachmentId: nil),
                parts: nil
            ),
            sizeEstimate: html.utf8.count
        )
    }
}

/// Returns its message, whatever it is given.
private final class FixedMessageProcessor: MessageProcessor, @unchecked Sendable {
    private let processedMessage: ProcessedMessage

    init(processedMessage: ProcessedMessage) {
        self.processedMessage = processedMessage
    }

    override func processGmailMessage(
        _ gmailMessage: GmailMessage,
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = []
    ) async throws -> ProcessedMessage? {
        processedMessage
    }
}

private struct SharingCorpus: Decodable {
    struct HTMLCase: Decodable { let inputHTML: String }
    struct RawSourceCase: Decodable { let input: String }
    struct SnippetCase: Decodable { let html: String? }

    let htmlToBubbleTextCases: [HTMLCase]
    let richHTMLDetectionCases: [HTMLCase]
    let rawSourceHTMLRecoveryCases: [RawSourceCase]
    let cleanedSnippetCases: [SnippetCase]
}
