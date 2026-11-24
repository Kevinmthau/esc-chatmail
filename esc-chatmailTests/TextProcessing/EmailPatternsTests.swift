import XCTest
@testable import esc_chatmail

/// `EmailPatterns.address` starts a match only at the start of a run of the
/// local part's characters (or where the previous match ended); it must find
/// exactly what the unguarded pattern found, one match or all of them.
final class EmailPatternsTests: XCTestCase {

    func testAddress_findsWhatTheUnguardedPatternFound() throws {
        let guarded = try XCTUnwrap(EmailPatterns.address)
        let unguarded = try NSRegularExpression(pattern: EmailPatterns.unguardedAddressPattern, options: [.caseInsensitive])
        let pieces = ["a", "Z", "0", "9", ".", "_", "%", "+", "-", "@", "com", ".co", ".c", "x@y.com", " ", "\n", "<", ">",
                      "\u{212A}", "\u{017F}", "é", "@@", "..", "a.b", ":", "/", "mailto:"]
        var state: UInt64 = 0xE3A1
        func random() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        for _ in 0..<50_000 {
            var text = ""
            for _ in 0..<Int(random() % 30) {
                text += pieces[Int(random() % UInt64(pieces.count))]
            }
            let length = (text as NSString).length
            let whole = NSRange(location: 0, length: length)
            XCTAssertEqual(guarded.firstMatch(in: text, range: whole)?.range, unguarded.firstMatch(in: text, range: whole)?.range, text)
            XCTAssertEqual(
                guarded.matches(in: text, range: whole).map(\.range),
                unguarded.matches(in: text, range: whole).map(\.range),
                text
            )
            XCTAssertEqual(
                guarded.stringByReplacingMatches(in: text, range: whole, withTemplate: ""),
                unguarded.stringByReplacingMatches(in: text, range: whole, withTemplate: ""),
                text
            )
        }
    }

    /// A line of 16,000 of these held a message's ingest for 14 to 35 s.
    /// Revert-check: the `(?:(?<![A-Z0-9._%+-])|\G)` guard in
    /// `EmailPatterns.address` (the run then exceeds its limit).
    func testLongRunsOfLocalPartCharacters_ingestQuickly() async throws {
        let count = 64_000
        for line in [
            String(repeating: "x", count: count),
            String(repeating: "a.", count: count / 2),
            String(repeating: "1", count: count),
            String(repeating: "a-", count: count / 2),
        ] {
            let html = "<p>Thanks,</p><p>Bob</p><p>" + line + "</p>"
            let message = GmailMessage(
                id: "long-run",
                threadId: "long-run-thread",
                labelIds: ["INBOX"],
                snippet: "long",
                historyId: "1",
                internalDate: "1704067200000",
                payload: MessagePart(
                    partId: "",
                    mimeType: "text/html",
                    filename: nil,
                    headers: [
                        MessageHeader(name: "From", value: "Sender <sender@example.com>"),
                        MessageHeader(name: "Content-Type", value: "text/html; charset=utf-8"),
                    ],
                    body: MessageBody(size: html.utf8.count, data: Data(html.utf8).base64EncodedString(), attachmentId: nil),
                    parts: nil
                ),
                sizeEstimate: html.utf8.count
            )
            let started = Date()
            _ = try await MessageProcessor().processGmailMessage(message, myAliases: [])
            XCTAssertLessThan(Date().timeIntervalSince(started), 10, String(line.prefix(8)))
        }
    }
}
