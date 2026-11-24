import XCTest
@testable import esc_chatmail

/// The quote patterns are line-anchored and bounded (Apple's "> On …, at …"
/// is bounded only, from its literal), so a crafted line costs at most the
/// product of its pattern's bounds at each start. Each input here carries the
/// pattern's required literal, so the literal shortcut does not skip it.
/// Unanchored with nested `.+`, the first took about 43 s at half this size.
/// Revert-check: the anchored, bounded patterns in
/// `PlainTextQuoteRemover.quoteIndicatorPatternStrings` (the run then
/// exceeds the timeout).
final class PlainTextQuoteRemoverPatternCostTests: XCTestCase {

    func testEarliestPatternMatch_craftedLines_finishQuickly() {
        let size = ChatBubbleTextProcessor.extractedTextUTF16Limit
        let inputs = [
            "On " + String(repeating: "a, ", count: size / 3) + "\n\nX wrote:",
            String(repeating: "> On , at x, ", count: size / 13) + "\n wrote:",
            String(repeating: "Am schrieb ", count: size / 11) + "\n:",
            String(repeating: "Le table ", count: size / 9) + "\nx a écrit :",
            String(repeating: "From: ", count: size / 6) + "\nSent: x",
            "x" + String(repeating: "\n", count: size) + "-- Forwarded message",
            String(repeating: "On " + String(repeating: "a, ", count: 133) + "\n", count: size / 403) + "X wrote:",
            // Apple Mail's quoted attributions in the other languages, each at
            // every start its literal allows, with its required literal present.
            String(repeating: "> Am x schrieb ", count: size / 15) + "\n:",
            String(repeating: "> Le x", count: size / 6) + "\n a écrit :",
            String(repeating: "> El x", count: size / 6) + "\n escribió:",
            String(repeating: "> Il x", count: size / 6) + "\n ha scritto:",
            String(repeating: "> Em x", count: size / 6) + "\n escreveu:",
            String(repeating: "> Op x schreef ", count: size / 15) + "\n:",
        ]
        let done = expectation(description: "patterns")
        let finished = LockedCount()
        let thread = Thread {
            for text in inputs {
                _ = PlainTextQuoteRemover.findEarliestPatternMatchWithAttribution(in: text)
                finished.increment()
            }
            done.fulfill()
        }
        thread.start()
        wait(for: [done], timeout: 20)
        XCTAssertEqual(finished.value, inputs.count)
    }
}

/// Apple Mail's quoted attributions stay unanchored, so each is tried at every
/// occurrence of its start literal ("> On ", "> Am "…), at about 36 µs each:
/// 4 to 5 s a megabyte of crafted text for each pattern, on the ingest
/// snippet's uncapped text. Past `quotedAttributionStartLimit` occurrences the
/// search stops a little after the last one it tries.
final class PlainTextQuoteRemoverQuotedStartLimitTests: XCTestCase {

    /// Measured on the iOS 27.0 simulator: 0.9 s bounded, 10 s unbounded.
    /// Revert-check: `quotedAttributionSearchRange` in
    /// `PlainTextQuoteRemover.findEarliestPatternMatchWithAttribution` (each
    /// input then takes over a second, and together they exceed the timeout).
    func testQuotedAttributions_halfAMegabyteOfStarts_finishQuickly() {
        let size = 512_000
        let inputs = [
            String(repeating: "> On , at x, ", count: size / 13) + "\n wrote:",
            String(repeating: "> Am x schrieb ", count: size / 15) + "\n:",
            String(repeating: "> Le x", count: size / 6) + "\n a écrit :",
            String(repeating: "> El x", count: size / 6) + "\n escribió:",
            String(repeating: "> Il x", count: size / 6) + "\n ha scritto:",
            String(repeating: "> Em x", count: size / 6) + "\n escreveu:",
            String(repeating: "> Op x schreef ", count: size / 15) + "\n:",
        ]
        let done = expectation(description: "patterns")
        let finished = LockedCount()
        let thread = Thread {
            for text in inputs {
                _ = PlainTextQuoteRemover.findEarliestPatternMatchWithAttribution(in: text)
                finished.increment()
            }
            done.fulfill()
        }
        thread.start()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(finished.value, inputs.count)
    }

    func testSearchRange_isTheWholeText_upToTheLimit() throws {
        let literal = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: "> Am "), options: [.caseInsensitive])
        let limit = PlainTextQuoteRemover.quotedAttributionStartLimit
        let atLimit = String(repeating: "> am x ", count: limit) + String(repeating: "y", count: 10_000)
        let whole = NSRange(location: 0, length: (atLimit as NSString).length)
        XCTAssertEqual(
            PlainTextQuoteRemover.quotedAttributionSearchRange(in: atLimit, fullRange: whole, startLiteral: literal),
            whole
        )

        let pastLimit = String(repeating: "> Am x ", count: limit + 1) + String(repeating: "y", count: 10_000)
        let pastWhole = NSRange(location: 0, length: (pastLimit as NSString).length)
        let lastTried = (limit - 1) * 7
        XCTAssertEqual(
            PlainTextQuoteRemover.quotedAttributionSearchRange(in: pastLimit, fullRange: pastWhole, startLiteral: literal),
            NSRange(location: 0, length: lastTried + PlainTextQuoteRemover.quotedAttributionSearchTail)
        )
    }

    /// An attribution at one of the tried starts is still found, and one past
    /// them is not: that is the only reading that changes.
    func testAttribution_isFoundAtATriedStart_andNotPastThem() {
        let limit = PlainTextQuoteRemover.quotedAttributionStartLimit
        let filler = String(repeating: "> Am x\n", count: limit + 10)
        let early = "Hi\n> Am 3. März schrieb Max:\n" + filler
        XCTAssertEqual(PlainTextQuoteRemover.findEarliestPatternMatchWithAttribution(in: early).0, 3)

        // Past the last tried start by more than the search's tail.
        let late = "Hi\n" + filler + filler + "> Am 3. März schrieb Max:"
        XCTAssertEqual(PlainTextQuoteRemover.findEarliestPatternMatchWithAttribution(in: late).0, late.count)
    }
}

/// Written by one thread, read after `wait(for:)`; the lock keeps the two
/// apart when the wait times out first.
private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
