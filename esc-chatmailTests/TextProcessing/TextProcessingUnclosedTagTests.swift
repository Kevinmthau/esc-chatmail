import XCTest
@testable import esc_chatmail

/// `TextProcessing.containsUnclosedOpeningTag` was rewritten as one pass;
/// its answers must be those of the walk it replaced, which `legacy` keeps
/// verbatim, and it must be linear in what a sender writes.
final class TextProcessingUnclosedTagTests: XCTestCase {

    func testContainsUnclosedOpeningTag_generatedText_matchesTheReplacedWalk() {
        var state: UInt64 = 0x0DD_C0DE_2026
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        let pieces = ["<", ">", "\"", "'", "a", "Z", "é", "1", " ", "<a", "</", "<<", "\"'", "x>", "<\u{301}", "\u{301}", "=", "<b c=\"", "'>'"]
        var mismatches: [String] = []
        for _ in 0..<20_000 {
            let text = (0..<Int(next() % 30)).map { _ in pieces[Int(next() % UInt64(pieces.count))] }.joined()
            if TextProcessing.containsUnclosedOpeningTag(text) != Self.legacy(text) {
                mismatches.append(text.debugDescription)
                if mismatches.count > 5 { break }
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    func testContainsUnclosedOpeningTag_writtenShapes_matchTheReplacedWalk() {
        for text in ["", "<", "a<", "<a", "<a>", "<a \">\"", "<a '>'>", "<a \">\" b>", "x<1 <b>", "<a\"", "<a'b'>", "<<a>"] {
            XCTAssertEqual(TextProcessing.containsUnclosedOpeningTag(text), Self.legacy(text), text.debugDescription)
        }
    }

    /// Walked from every `<`, `<a` repeated 20,000 times and then `>` took
    /// 4 s; 200,000 here would take minutes, past the timeout.
    /// Revert-check: the one-pass body of `containsUnclosedOpeningTag`.
    func testContainsUnclosedOpeningTag_longRunOfOpenTags_isLinear() {
        let text = String(repeating: "<a", count: 200_000) + ">"
        let done = expectation(description: "scan")
        let answer = LockedAnswer()
        let thread = Thread {
            answer.value = TextProcessing.containsUnclosedOpeningTag(text)
            done.fulfill()
        }
        thread.start()
        wait(for: [done], timeout: 20)
        XCTAssertEqual(answer.value, false)
    }

    /// The function as it was before the rewrite, with its `tagEndIndex`.
    private static func legacy(_ html: String) -> Bool {
        var index = html.startIndex
        while let tagStart = html[index...].firstIndex(of: "<") {
            let nameStart = html.index(after: tagStart)
            guard nameStart < html.endIndex else { return false }
            if html[nameStart].isLetter, legacyTagEndIndex(in: html, from: nameStart) == nil {
                return true
            }
            index = nameStart
        }
        return false
    }

    private static func legacyTagEndIndex(in html: String, from startIndex: String.Index) -> String.Index? {
        var index = startIndex
        var quote: Character?
        while index < html.endIndex {
            let character = html[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }
}

/// Written by one thread, read after `wait(for:)`.
private final class LockedAnswer: @unchecked Sendable {
    var value: Bool?
}
