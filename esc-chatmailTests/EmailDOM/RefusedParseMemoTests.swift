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
        XCTAssertEqual(RefusedParseMemo.shared.hitCount, hits + 1)
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

    /// A body the scan admits, or one the measuring thread admits, is never
    /// recorded, and ordinary mail is never looked up.
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
    /// the measuring thread refuses is parsed for the first of them only (7
    /// parses of 1.1 s each, 10.4 s for the message, before).
    /// Revert-check: `RefusedParseMemo.shared.record` in
    /// `EmailDOMParseAdmission.admittedParse` (no stage is answered from the
    /// memo).
    func testProcessGmailMessage_bodyRefusedByItsParse_isParsedOnce() async throws {
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
