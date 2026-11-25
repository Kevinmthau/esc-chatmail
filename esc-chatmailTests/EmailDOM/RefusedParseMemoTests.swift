import XCTest
import SwiftSoup
@testable import esc_chatmail

final class RefusedParseMemoTests: XCTestCase {
    /// Nested past `maximumDepth`, which the scan cannot be sure of without
    /// a parse (its bound is between the two limits), with text unique to
    /// the test so no earlier test's verdict is found.
    private func bodyRefusedByItsParse() -> String {
        String(repeating: "<div>", count: 700) + "<p>\(UUID().uuidString)</p>"
            + String(repeating: "<p>line of text</p>", count: 200)
    }

    /// A body only the measuring thread can refuse is parsed once: the
    /// second ask is answered with the first refusal, unparsed.
    /// Revert-check: `RefusedParseMemo.shared.record` in
    /// `EmailDOMParseAdmission.admittedParse` (no answer comes from the memo).
    func testParseDocument_bodyRefusedByItsParse_isRefusedAgainWithoutParsing() throws {
        let html = bodyRefusedByItsParse()
        let bound = EmailDOMParseAdmission.estimatedDepth(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
        XCTAssertGreaterThan(bound, EmailDOMParseAdmission.maximumDepth)
        XCTAssertLessThanOrEqual(bound, EmailDOMParseAdmission.maximumBoundForMeasuredParse)

        var first: EmailDOMParseRefusal?
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html)) { first = $0 as? EmailDOMParseRefusal }
        guard case let .nestingTooDeep(depth, _)? = first else {
            return XCTFail("\(String(describing: first))")
        }
        XCTAssertGreaterThan(depth, EmailDOMParseAdmission.maximumDepth)

        let hits = RefusedParseMemo.shared.hitCount
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html)) { error in
            XCTAssertEqual(error as? EmailDOMParseRefusal, first)
        }
        XCTAssertGreaterThanOrEqual(RefusedParseMemo.shared.hitCount, hits + 1)
    }

    /// A body the scan lets parse in place, whose attribute names the
    /// measured depth then refuses (`attributeWalkRefusal`), is parsed once
    /// too: its refusal is recorded and the next ask is answered with it.
    /// Revert-check: the `attributeWalkRefusal` term of
    /// `EmailDOMParseAdmission.mayBeRefusedOnlyByItsParse` (no key is made,
    /// so nothing is recorded).
    func testParseDocument_bodyRefusedForItsAttributeWalks_isRecordedAndRefusedAgain() throws {
        var html = String(repeating: "<div>", count: 500) + "<p>\(UUID().uuidString)</p>"
        for tag in 0..<1_000 {
            html += "<br" + (0..<20).map { " n\(tag)x\($0)=1" }.joined() + ">"
        }
        let cost = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
        XCTAssertLessThanOrEqual(cost.depth, EmailDOMParseAdmission.maximumDepth)
        XCTAssertNil(cost.excessWork)

        var first: EmailDOMParseRefusal?
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html)) { first = $0 as? EmailDOMParseRefusal }
        guard case let .tooCostlyToParse(_, limit)? = first else {
            return XCTFail("\(String(describing: first))")
        }
        XCTAssertEqual(limit, EmailDOMParseAdmission.maximumAttributeWalkWork)
        XCTAssertEqual(RefusedParseMemo.shared.refusal(for: RefusedParseMemo.Key(html, kind: .document)), first)

        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html)) { error in
            XCTAssertEqual(error as? EmailDOMParseRefusal, first)
        }
    }

    /// The same bytes parsed another way are a tree of their own.
    func testKey_sameBytesParsedAnotherWay_isAnotherKey() {
        let html = "<div>x</div>"
        XCTAssertEqual(RefusedParseMemo.Key(html, kind: .document), RefusedParseMemo.Key(html, kind: .document))
        XCTAssertNotEqual(RefusedParseMemo.Key(html, kind: .document), RefusedParseMemo.Key(html, kind: .bodyFragment))
        XCTAssertNotEqual(
            RefusedParseMemo.Key(html, kind: .fragment(context: "tbody")),
            RefusedParseMemo.Key(html, kind: .fragment(context: "tr"))
        )
        XCTAssertNotEqual(RefusedParseMemo.Key(html, kind: .document), RefusedParseMemo.Key(html + " ", kind: .document))
    }

    /// A body the scan admits, or one the measuring thread admits, is
    /// parsed and handed back, and nothing is recorded for it.
    /// HONEST SCOPE: only a refusal is ever recorded, so this pins that the
    /// measuring thread still admits such a body; that ordinary mail is
    /// never hashed is not observable here.
    func testParseDocument_admittedBodies_areNotRecorded() throws {
        let memo = RefusedParseMemo.shared
        let ordinary = "<div><p>hello \(UUID().uuidString)</p></div>"
        // A bound past `maximumDepth` over a shallow tree: forms inside a
        // form, which SwiftSoup ignores.
        let measuredAndAdmitted = String(repeating: "<form>x", count: 1_000) + UUID().uuidString
        XCTAssertGreaterThan(EmailDOMParseAdmission.estimatedDepth(of: measuredAndAdmitted), EmailDOMParseAdmission.maximumDepth)
        for html in [ordinary, measuredAndAdmitted] {
            XCTAssertNoThrow(try EmailDOMParseAdmission.parseDocument(html))
            XCTAssertNil(memo.refusal(for: RefusedParseMemo.Key(html, kind: .document)))
        }
    }

    /// The memo keeps only its newest `capacity` refusals.
    func testRecord_pastCapacity_forgetsTheOldest() {
        let memo = RefusedParseMemo()
        let keys = (0...RefusedParseMemo.capacity).map { RefusedParseMemo.Key("body \($0)", kind: .document) }
        let refusal = EmailDOMParseRefusal.nestingTooDeep(depth: 600, limit: 512)
        for key in keys {
            memo.record(refusal, for: key)
        }
        XCTAssertNil(memo.refusal(for: keys[0]))
        XCTAssertEqual(memo.refusal(for: keys[1]), refusal)
        XCTAssertEqual(memo.refusal(for: keys[keys.count - 1]), refusal)
    }

    /// Processing a message asks for its body at every cleanup stage; a body
    /// the measuring thread refuses is parsed once for each way it is parsed
    /// (document, body fragment), and the other stages are answered from the
    /// memo (7 parses of 1.1 s each, 10.4 s for the message, before; 2 and
    /// 4.9 s after).
    /// Revert-check: `RefusedParseMemo.shared.record` in
    /// `EmailDOMParseAdmission.admittedParse` (no stage is answered from the
    /// memo).
    func testProcessGmailMessage_bodyRefusedByItsParse_isParsedOnceForEachKind() async throws {
        let html = bodyRefusedByItsParse()
        let message = GmailMessage(
            id: "refused-once", threadId: "refused-once-thread", labelIds: ["INBOX"], snippet: "line of text",
            historyId: "1", internalDate: "1704067200000",
            payload: MessagePart(
                partId: "", mimeType: "text/html", filename: nil,
                headers: [
                    MessageHeader(name: "From", value: "Sender <sender@example.com>"),
                    MessageHeader(name: "Content-Type", value: "text/html; charset=utf-8"),
                ],
                body: MessageBody(size: html.utf8.count, data: Data(html.utf8).base64EncodedString(), attachmentId: nil),
                parts: nil
            ),
            sizeEstimate: html.utf8.count
        )
        let hits = RefusedParseMemo.shared.hitCount
        let processed = try await MessageProcessor().processGmailMessage(message, myAliases: [])
        XCTAssertNotNil(processed)
        XCTAssertGreaterThanOrEqual(RefusedParseMemo.shared.hitCount, hits + 4)
    }
}
