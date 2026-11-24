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
