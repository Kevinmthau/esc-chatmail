import XCTest
@testable import esc_chatmail

/// A body a mail client split around something it placed in the text
/// (architecture review gap-message-shape-extremes#3, gap-mime-decoding-i18n#4):
/// iPhone Mail sends a photo placed mid-message as multipart/mixed
/// [text, photo, text], and the walk kept only the words before the photo.
/// `MIMEBodyExtractor` joins the text after an inline file to the body; these
/// pin what joins, what does not, and that a continuation is fetched under
/// the body-materialization contract.
final class MessageProcessorSplitBodyTests: XCTestCase {

    // MARK: - Plain text

    /// Revert-check: the continuation branch of `MIMEBodyExtractor.walk`.
    func testPlainTextSplitAroundInlinePhoto_keepsTheWordsAfterThePhoto() async throws {
        let message = makeMessage(parts: [
            textPart("0.0", "text/plain", "Look at this TOKEN_BEFORE"),
            inlinePhoto("0.1"),
            textPart("0.2", "text/plain", "TOKEN_AFTER the photo")
        ])

        let processed = try await process(message)

        XCTAssertEqual(processed.plainTextBody, "Look at this TOKEN_BEFORE\n\nTOKEN_AFTER the photo")
        XCTAssertEqual(processed.canonicalContent?.plainText, processed.plainTextBody)
        XCTAssertTrue(processed.chatPreviewText?.contains("TOKEN_AFTER") == true)
        XCTAssertEqual(processed.attachmentInfo.count, 1)
    }

    func testPlainTextSplitAroundTwoPhotos_keepsEveryFragmentInOrder() async throws {
        let message = makeMessage(parts: [
            textPart("0.0", "text/plain", "ONE"),
            inlinePhoto("0.1"),
            textPart("0.2", "text/plain", "TWO"),
            inlinePhoto("0.3"),
            inlinePhoto("0.4"),
            textPart("0.5", "text/plain", "THREE")
        ])

        let processed = try await process(message)

        XCTAssertEqual(processed.plainTextBody, "ONE\n\nTWO\n\nTHREE")
    }

    /// A file sent with an `attachment` disposition is not something placed in
    /// the text, and a list server's footer after it is not the sender's.
    ///
    /// Revert-check: the `inline` test in `MIMEBodyExtractor.isInlineFilePart`
    /// (returning true for any file).
    func testTextAfterAnAttachedFile_isNotJoined() async throws {
        let message = makeMessage(parts: [
            textPart("0.0", "text/plain", "REAL_BODY"),
            filePart("0.1", mimeType: "application/pdf", filename: "report.pdf", disposition: "attachment"),
            textPart("0.2", "text/plain", "LIST_FOOTER")
        ])

        let processed = try await process(message)

        XCTAssertEqual(processed.plainTextBody, "REAL_BODY")
    }

    /// A disposition whose parameters say "inline" is still an attachment.
    func testAttachmentDispositionNamingInline_isNotJoined() async throws {
        let message = makeMessage(parts: [
            textPart("0.0", "text/plain", "REAL_BODY"),
            filePart(
                "0.1",
                mimeType: "image/png",
                filename: "inline.png",
                disposition: "attachment; filename=\"inline.png\""
            ),
            textPart("0.2", "text/plain", "LIST_FOOTER")
        ])

        let processed = try await process(message)

        XCTAssertEqual(processed.plainTextBody, "REAL_BODY")
    }

    /// Joining happens in a multipart/mixed only: the parts of a
    /// multipart/related are the root's resources (RFC 2387).
    ///
    /// Revert-check: `isMultipartMixed` in `MIMEBodyExtractor.walk`
    /// (joining in every container).
    func testRelatedParts_areNotJoined() async throws {
        let message = makeMessage(mimeType: "multipart/related", parts: [
            textPart("0.0", "text/html", "<html><body><p>ROOT</p></body></html>"),
            inlinePhoto("0.1"),
            textPart("0.2", "text/html", "<html><body><p>RESOURCE</p></body></html>")
        ])

        let processed = try await process(message)

        XCTAssertTrue(processed.storedHTML?.contains("ROOT") == true)
        XCTAssertFalse(processed.storedHTML?.contains("RESOURCE") == true)
    }

    /// The trailing empty part Apple Mail sends after a photo adds nothing:
    /// no blank line, no separator.
    func testEmptyTrailingFragment_leavesTheBodyAsItWas() async throws {
        let message = makeMessage(parts: [
            textPart("0.0", "text/plain", "ONLY_WORDS"),
            inlinePhoto("0.1"),
            textPart("0.2", "text/plain", "  \n")
        ])

        let processed = try await process(message)

        XCTAssertEqual(processed.plainTextBody, "ONLY_WORDS")
    }

    // MARK: - HTML

    /// Apple Mail's HTML shape: the plain alternative, then a multipart/mixed
    /// of HTML fragments around an inline PDF. Both fragments are stored, once
    /// each, with nothing standing in for the PDF.
    func testHTMLSplitAroundInlinePDF_storesBothFragmentsInOneBody() async throws {
        let message = makeMessage(mimeType: "multipart/alternative", parts: [
            textPart("0.0", "text/plain", "SEG_A\n\nSEG_B"),
            MessagePart(
                partId: "0.1",
                mimeType: "multipart/mixed",
                filename: nil,
                headers: nil,
                body: nil,
                parts: [
                    textPart("0.1.0", "text/html", Self.fragmentA),
                    filePart("0.1.1", mimeType: "application/pdf", filename: "plan.pdf", disposition: "inline"),
                    textPart("0.1.2", "text/html", Self.fragmentB)
                ]
            )
        ])

        let processed = try await process(message)
        let storedHTML = try XCTUnwrap(processed.storedHTML)

        XCTAssertEqual(
            storedHTML,
            "<html><head><style>p{color:red}</style></head><body dir=\"auto\"><div>SEG_A</div>"
                + "<div>SEG_B</div></body></html>"
        )
        XCTAssertTrue(processed.chatPreviewText?.contains("SEG_B") == true)
        XCTAssertFalse(storedHTML.contains("plan.pdf"))
    }

    /// A fragment with nothing visible is left out, as recovery leaves out a
    /// hidden-only candidate.
    func testHiddenHTMLFragment_isNotJoined() async throws {
        let message = makeMessage(parts: [
            textPart("0.0", "text/html", Self.fragmentA),
            inlinePhoto("0.1"),
            textPart("0.2", "text/html", "<html><body><div style=\"display:none\">TRACKER</div></body></html>")
        ])

        let processed = try await process(message)

        XCTAssertFalse(processed.storedHTML?.contains("TRACKER") == true)
    }

    // MARK: - Fetching a continuation

    /// A continuation served by attachmentId is fetched under the body's own
    /// contract: a transient failure throws, so the message is not stored
    /// without the words after the photo behind an advancing cursor.
    ///
    /// Revert-check: answering nil for a failed continuation fetch in
    /// `MIMEBodyExtractor.joiningContinuation` (`try?` on `decodedBody`).
    func testTransientFailureFetchingAContinuation_throws() async {
        let message = makeMessage(parts: [
            textPart("0.0", "text/plain", "BEFORE"),
            inlinePhoto("0.1"),
            largeTextPart("0.2", "text/plain", attachmentId: "continuation")
        ])
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in
            throw APIError.rateLimited(retryAfter: 5)
        })

        do {
            _ = try await processor.processGmailMessage(message, myAliases: [])
            XCTFail("A continuation that could not be fetched must not leave a shorter body")
        } catch let error as APIError {
            guard case .rateLimited = error else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
        } catch {
            XCTFail("Expected APIError.rateLimited, got \(error)")
        }
    }

    func testContinuationGoneServerSide_keepsTheFirstFragment() async throws {
        let message = makeMessage(parts: [
            textPart("0.0", "text/plain", "BEFORE"),
            inlinePhoto("0.1"),
            largeTextPart("0.2", "text/plain", attachmentId: "continuation")
        ])
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in
            throw APIError.notFound("attachment")
        })

        let processed = try await XCTUnwrapAsync(await processor.processGmailMessage(message, myAliases: []))

        XCTAssertEqual(processed.plainTextBody, "BEFORE")
    }

    func testContinuationServedByAttachmentId_isFetchedAndJoined() async throws {
        let message = makeMessage(parts: [
            textPart("0.0", "text/plain", "BEFORE"),
            inlinePhoto("0.1"),
            largeTextPart("0.2", "text/plain", attachmentId: "continuation")
        ])
        let processor = MessageProcessor(fetchAttachmentData: { _, attachmentId in
            XCTAssertEqual(attachmentId, "continuation")
            return Data("AFTER".utf8)
        })

        let processed = try await XCTUnwrapAsync(await processor.processGmailMessage(message, myAliases: []))

        XCTAssertEqual(processed.plainTextBody, "BEFORE\n\nAFTER")
        XCTAssertTrue(
            processed.attachmentInfo.allSatisfy { $0.id != "continuation" },
            "A body served by attachmentId is not a file"
        )
    }

    // MARK: - Bounds

    /// Revert-check: `ContinuationBudget.admitsAnother`'s count.
    func testContinuationsPastTheCountBound_areLeftOut() async throws {
        var parts = [textPart("p0", "text/plain", "F0")]
        for index in 1...20 {
            parts.append(inlinePhoto("i\(index)"))
            parts.append(textPart("p\(index)", "text/plain", "F\(index)"))
        }

        let processed = try await process(makeMessage(parts: parts))
        let fragments = try XCTUnwrap(processed.plainTextBody).components(separatedBy: "\n\n")

        XCTAssertEqual(fragments.count, MIMEBodyExtractor.maximumContinuationsPerKind + 1)
        XCTAssertEqual(fragments.last, "F\(MIMEBodyExtractor.maximumContinuationsPerKind)")
    }

    /// A continuation whose declared size passes the byte bound is not
    /// fetched. (HTML, because a message with no HTML has its text parts read
    /// by the embedded-HTML probe, which fetches them on its own terms.)
    ///
    /// Revert-check: the declared-size test in
    /// `MIMEBodyExtractor.joiningContinuation`.
    func testContinuationDeclaredLargerThanTheByteBound_isNotFetched() async throws {
        var oversized = largeTextPart("0.2", "text/html", attachmentId: "huge")
        oversized = MessagePart(
            partId: oversized.partId,
            mimeType: oversized.mimeType,
            filename: oversized.filename,
            headers: oversized.headers,
            body: MessageBody(
                size: MIMEBodyExtractor.maximumContinuationUTF8Bytes + 1,
                data: nil,
                attachmentId: "huge"
            ),
            parts: nil
        )
        let message = makeMessage(parts: [
            textPart("0.0", "text/html", Self.fragmentA),
            inlinePhoto("0.1"),
            oversized
        ])
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in
            XCTFail("A continuation past the byte bound must not be fetched")
            return Data()
        })

        let processed = try await XCTUnwrapAsync(await processor.processGmailMessage(message, myAliases: []))

        XCTAssertEqual(processed.storedHTML, Self.fragmentA)
    }

    /// A refused continuation counts toward the bound: it was fetched
    /// before it could be refused, so a sender could otherwise have any
    /// number of blank or invisible fragments fetched, each a fresh chance of
    /// a transient failure that blocks the message.
    ///
    /// Revert-check: counting only joined continuations in
    /// `MIMEBodyExtractor.joiningContinuation` (moving the `readCount`
    /// increment after the join).
    func testRefusedContinuations_countTowardTheBound() async throws {
        var parts = [textPart("0", "text/html", Self.fragmentA)]
        for index in 1...100 {
            parts.append(inlinePhoto("i\(index)"))
            parts.append(largeTextPart("h\(index)", "text/html", attachmentId: "hidden-\(index)"))
        }
        let fetches = FetchCounter()
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in
            fetches.increment()
            return Data("<html><body><div hidden>x</div></body></html>".utf8)
        })

        let processed = try await XCTUnwrapAsync(
            await processor.processGmailMessage(makeMessage(parts: parts), myAliases: [])
        )

        XCTAssertEqual(processed.storedHTML, Self.fragmentA)
        XCTAssertEqual(fetches.count, MIMEBodyExtractor.maximumContinuationsPerKind)
    }

    /// A refused continuation spends its bytes too: it was fetched and
    /// checked for visible content, which on web is quadratic in it.
    /// Two 1.5 MiB invisible fragments leave less than the third's declared
    /// 1 MiB, so the third is not fetched.
    ///
    /// Revert-check: counting `readBytes` only for a joined continuation in
    /// `MIMEBodyExtractor.joiningContinuation`.
    func testRefusedContinuations_spendTheByteBound() async throws {
        let hidden = "<html><body><div hidden>" + String(repeating: "x", count: 1_500_000) + "</div></body></html>"
        func continuation(_ index: Int, declaredSize: Int) -> MessagePart {
            MessagePart(
                partId: "h\(index)",
                mimeType: "text/html",
                filename: nil,
                headers: nil,
                body: MessageBody(size: declaredSize, data: nil, attachmentId: "hidden-\(index)"),
                parts: nil
            )
        }
        let message = makeMessage(parts: [
            textPart("0", "text/html", Self.fragmentA),
            inlinePhoto("i1"),
            continuation(1, declaredSize: 10),
            inlinePhoto("i2"),
            continuation(2, declaredSize: 10),
            inlinePhoto("i3"),
            continuation(3, declaredSize: 1024 * 1024)
        ])
        let fetches = FetchCounter()
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in
            fetches.increment()
            return Data(hidden.utf8)
        })

        let processed = try await XCTUnwrapAsync(await processor.processGmailMessage(message, myAliases: []))

        XCTAssertEqual(processed.storedHTML, Self.fragmentA)
        XCTAssertEqual(fetches.count, 2)
    }

    /// A container walked only for the kind still missing is not asked for
    /// the other: its HTML would be dropped, so its continuations were
    /// fetched for nothing, and they spent the bound that a later
    /// continuation recovery joins (recovery asks for HTML alone).
    ///
    /// Revert-check: passing `kinds` rather than `missingKinds` to the
    /// child's walk in `MIMEBodyExtractor.walk`.
    func testContainerWalkedForPlainText_fetchesNoHTMLContinuation() async throws {
        let message = makeMessage(parts: [
            textPart("0.0", "text/html", Self.fragmentA),
            MessagePart(
                partId: "0.1",
                mimeType: "multipart/mixed",
                filename: nil,
                headers: nil,
                body: nil,
                parts: [
                    textPart("0.1.0", "text/html", Self.fragmentB),
                    inlinePhoto("0.1.1"),
                    largeTextPart("0.1.2", "text/html", attachmentId: "dropped-anyway"),
                    textPart("0.1.3", "text/plain", "PLAIN")
                ]
            )
        ])

        let processed = try await process(message)

        XCTAssertEqual(processed.storedHTML, Self.fragmentA)
        XCTAssertEqual(processed.plainTextBody, "PLAIN")
    }

    // MARK: - Joining HTML

    func testJoinedHTML_putsTheFragmentsBodyContentBeforeTheClosingBodyTag() {
        XCTAssertEqual(
            MIMEBodyExtractor.joinedHTML(
                "<HTML><BODY><p>A</p></BODY></HTML>",
                appending: "<html><head><title>x</title></head><Body class=\"b\"><p>B</p></bOdY></html>"
            ),
            "<HTML><BODY><p>A</p><p>B</p></BODY></HTML>"
        )
    }

    func testJoinedHTML_greaterThanInAQuotedAttributeDoesNotEndTheBodyTag() {
        XCTAssertEqual(
            MIMEBodyExtractor.joinedHTML(
                "<body>A</body>",
                appending: "<body onload=\"a>b\" data-x='c>d'>B</body>"
            ),
            "<body>AB</body>"
        )
    }

    func testJoinedHTML_bodyLikeTagNamesAreNotTheBody() {
        XCTAssertEqual(
            MIMEBodyExtractor.joinedHTML("<body>A</body>", appending: "<bodyguard>B</bodyguard>"),
            "<body>A<bodyguard>B</bodyguard></body>"
        )
    }

    func testJoinedHTML_withoutClosingTags_appendsAtTheEnd() {
        XCTAssertEqual(
            MIMEBodyExtractor.joinedHTML("<div>A</div>", appending: "<div>B</div>"),
            "<div>A</div><div>B</div>"
        )
        XCTAssertEqual(
            MIMEBodyExtractor.joinedHTML("<html><div>A</div></html>", appending: "<div>B</div>"),
            "<html><div>A</div><div>B</div></html>"
        )
    }

    func testJoinedHTML_keepsNonASCIITextWhole() {
        XCTAssertEqual(
            MIMEBodyExtractor.joinedHTML("<body>Ünïcödé 😀</body>", appending: "<body>İstanbul ſ</body>"),
            "<body>Ünïcödé 😀İstanbul ſ</body>"
        )
    }

    /// The seam is trimmed by a scan, not a regular expression, which
    /// backtracked through every run of line breaks in the sender's text: a
    /// run of 40,000 took 15 s in ICU (review round 1 of PR 466).
    ///
    /// Revert-check: trimming with `[\\r\\n]+\\z` again in
    /// `MIMEBodyExtractor.joinedPlainText`. HONEST SCOPE: this asserts a time,
    /// with a margin of about a hundred times the linear scan's.
    func testJoinedPlainText_aLongRunOfLineBreaksInsideTheBaseIsLinear() {
        let base = "A" + String(repeating: "\n", count: 60_000) + "x\n\n"
        let start = Date()

        let joined = MIMEBodyExtractor.joinedPlainText(base, appending: "B")

        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(joined, "A" + String(repeating: "\n", count: 60_000) + "x\n\nB")
    }

    func testJoinedPlainText_makesTheSeamOneBlankLine() {
        XCTAssertEqual(MIMEBodyExtractor.joinedPlainText("A\r\n\r\n", appending: "\n\nB\n"), "A\n\nB\n")
    }

    // MARK: - Fixtures

    private static let fragmentA =
        "<html><head><style>p{color:red}</style></head><body dir=\"auto\"><div>SEG_A</div></body></html>"
    private static let fragmentB =
        "<html><head><meta charset=\"utf-8\"></head><body dir=\"auto\"><div>SEG_B</div></body></html>"

    private func process(_ message: GmailMessage) async throws -> ProcessedMessage {
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in
            XCTFail("No part in this message is served by attachmentId")
            return Data()
        })
        return try await XCTUnwrapAsync(await processor.processGmailMessage(message, myAliases: []))
    }

    private func makeMessage(mimeType: String = "multipart/mixed", parts: [MessagePart]) -> GmailMessage {
        GmailMessage(
            id: "split-body",
            threadId: "split-body-thread",
            labelIds: ["INBOX"],
            snippet: "Snippet",
            historyId: "1",
            internalDate: "1700000000000",
            payload: MessagePart(
                partId: "0",
                mimeType: mimeType,
                filename: nil,
                headers: [
                    MessageHeader(name: "From", value: "Alice <alice@example.com>"),
                    MessageHeader(name: "To", value: "me@example.com"),
                    MessageHeader(name: "Subject", value: "Split body")
                ],
                body: nil,
                parts: parts
            ),
            sizeEstimate: nil
        )
    }

    private func textPart(_ partId: String, _ mimeType: String, _ text: String) -> MessagePart {
        MessagePart(
            partId: partId,
            mimeType: mimeType,
            filename: nil,
            headers: [
                MessageHeader(name: "Content-Type", value: "\(mimeType); charset=utf-8"),
                MessageHeader(name: "Content-Transfer-Encoding", value: "8bit")
            ],
            body: MessageBody(size: text.utf8.count, data: Data(text.utf8).base64EncodedString(), attachmentId: nil),
            parts: nil
        )
    }

    private func largeTextPart(_ partId: String, _ mimeType: String, attachmentId: String) -> MessagePart {
        MessagePart(
            partId: partId,
            mimeType: mimeType,
            filename: nil,
            headers: [
                MessageHeader(name: "Content-Type", value: "\(mimeType); charset=utf-8"),
                MessageHeader(name: "Content-Transfer-Encoding", value: "8bit")
            ],
            body: MessageBody(size: 30_000, data: nil, attachmentId: attachmentId),
            parts: nil
        )
    }

    private func inlinePhoto(_ partId: String) -> MessagePart {
        filePart(partId, mimeType: "image/jpeg", filename: "image\(partId).jpeg", disposition: "inline; filename=\"image\(partId).jpeg\"")
    }

    private func filePart(_ partId: String, mimeType: String, filename: String, disposition: String) -> MessagePart {
        MessagePart(
            partId: partId,
            mimeType: mimeType,
            filename: filename,
            headers: [MessageHeader(name: "Content-Disposition", value: disposition)],
            body: MessageBody(size: 4, data: Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString(), attachmentId: nil),
            parts: nil
        )
    }
}

/// Counts attachment fetches from the processor's `@Sendable` closure.
/// `@unchecked Sendable`: `lock` guards `value`.
private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func XCTUnwrapAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
