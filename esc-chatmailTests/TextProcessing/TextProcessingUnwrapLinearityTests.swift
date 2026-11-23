import XCTest
@testable import esc_chatmail

/// `TextProcessing.unwrapEmailLineBreaks` was rewritten to be linear; its
/// output must be byte-identical to the function it replaced, which
/// `LegacyUnwrap` keeps verbatim (with the private helpers it called) from
/// the commit before the rewrite. Compared over every golden-corpus text
/// and over seeded generated text built from what the join checks read:
/// sign-offs and names, delimiter lines, punctuation-only and
/// whitespace-only lines, Unicode whitespace and line separators, list
/// items, URLs, capitals, and runs of blank lines.
///
/// HONEST SCOPE: these pin that the output did not change, not that the
/// rewrite is linear. Reverting `UnwrapParagraph` to the old re-reading
/// makes nothing here fail; `testUnwrap_longJoinableRun_isUnchangedAndCompletes`
/// only gets slower (seconds, not minutes, at its size). No test times it.
final class TextProcessingUnwrapLinearityTests: XCTestCase {

    func testUnwrap_goldenCorpusTexts_matchTheReplacedFunction() throws {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "golden_message_corpus", withExtension: "json"))
        let corpus = try JSONDecoder().decode(UnwrapCorpus.self, from: Data(contentsOf: url))
        var texts = corpus.plainTextQuoteCleanupCases.map(\.input)
        texts += corpus.htmlToBubbleTextCases.map { TextProcessing.extractPlainText(from: $0.inputHTML) }
        texts += corpus.cleanedSnippetCases.compactMap(\.plainText)
        XCTAssertGreaterThan(texts.count, 150)
        for text in texts {
            XCTAssertEqual(TextProcessing.unwrapEmailLineBreaks(from: text), LegacyUnwrap.unwrap(text), String(text.prefix(80)))
        }
    }

    func testUnwrap_generatedTexts_matchTheReplacedFunction() {
        var generator = UnwrapTextGenerator(seed: 0x00C0_FFEE_2026)
        var mismatches: [String] = []
        for iteration in 0..<6_000 {
            let text = generator.text(lineCount: 2 + iteration % 60)
            if TextProcessing.unwrapEmailLineBreaks(from: text) != LegacyUnwrap.unwrap(text) {
                mismatches.append(text.debugDescription)
                if mismatches.count > 5 { break }
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    /// The shapes the rewrite keeps state for, written out.
    func testUnwrap_signOffAndDelimiterShapes_matchTheReplacedFunction() {
        let texts = [
            "Thanks,\nJane Doe",
            "thanks\njane doe",
            "see you then\nthanks\njane doe",
            "a\nb\nc\nThanks!\nJane",
            "best regards\u{2028}\njane doe",
            "\u{2028}\nbest\njane doe",
            "!!!best\njane doe",
            "best regards ,\njane doe",
            "best\nregards\njane doe",
            "#### \n####\nbest\njane",
            "--\nJane",
            "-\n-\nx",
            "___\nname here",
            "a\n\n\n\nb\n\n\nc",
            "a\n \n\u{00A0}\nb",
            "\u{2028}\n\u{2028}\nx",
            "\u{212A}ind regards\njane doe",
            "İ\nthanks",
            "\u{301}\nthanks\nbob smith",
        ]
        for text in texts {
            XCTAssertEqual(TextProcessing.unwrapEmailLineBreaks(from: text), LegacyUnwrap.unwrap(text), text.debugDescription)
        }
    }

    /// A long run of joinable lines, the shape that was quadratic. Linear,
    /// 200 KB takes well under a second; quadratic, it took minutes. The
    /// comparison with the replaced function uses a smaller run so this
    /// test stays fast either way.
    func testUnwrap_longJoinableRun_isUnchangedAndCompletes() {
        let small = (0..<2_000).map { "[\($0)] backup ok: file_\($0).dat" }.joined(separator: "\n")
        XCTAssertEqual(TextProcessing.unwrapEmailLineBreaks(from: small), LegacyUnwrap.unwrap(small))

        let large = (0..<6_000).map { "[\($0)] backup ok: file_\($0).dat" }.joined(separator: "\n")
        let unwrapped = TextProcessing.unwrapEmailLineBreaks(from: large)
        XCTAssertFalse(unwrapped.contains("\n"))
        XCTAssertTrue(unwrapped.hasSuffix("file_5999.dat"))
    }
}

private struct UnwrapCorpus: Decodable {
    struct PlainCase: Decodable { let input: String }
    struct HTMLCase: Decodable { let inputHTML: String }
    struct SnippetCase: Decodable { let plainText: String? }

    let plainTextQuoteCleanupCases: [PlainCase]
    let htmlToBubbleTextCases: [HTMLCase]
    let cleanedSnippetCases: [SnippetCase]
}

private struct UnwrapTextGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private mutating func pick(_ options: [String]) -> String {
        options[Int(next() % UInt64(options.count))]
    }

    private static let lines = [
        "", "", "", " ", "\t", "\u{00A0}", "\u{2028}", "\u{000B}", "\u{3000}",
        "thanks", "Thanks,", "best regards", "Best Regards!", "kind regards ,", "cheers", "thx",
        "with best regards", "thanks & regards", "regards.", "  thanks  ", "...thanks...", "\u{212A}ind regards",
        "jane doe", "Jane Doe", "bob", "Mary Ann Smith", "j. r. r. tolkien", "a b c d e",
        "--", "-- ", "---", "___", "—", "–", "-", "----------", "__--__", "- -",
        "####", ",,,,", "!!!", "...", "::::", "~~~~", "****", "''", "\"\"",
        "1. first item", "a) option", "- bullet", "* star", "• dot", "(a) paren",
        "https://example.com/x", "www.example.com", "HTTP://EXAMPLE.COM",
        "the quick brown fox", "jumps over the lazy dog", "and more words here",
        "Sentence starts here", "ends with period.", "ends with colon:", "what?", "wow!",
        "\u{301}accent", "İstanbul", "σίγμα Σ", "emoji 😀 line", "x",
        "[12:00:01] backup ok", "file_001.dat", "a,b,c,d", "{ \"key\": 1 }",
    ]

    mutating func text(lineCount: Int) -> String {
        (0..<lineCount).map { _ in pick(Self.lines) }.joined(separator: pick(["\n", "\n", "\n", "\r\n", "\r"]))
    }
}

/// `TextProcessing.unwrapEmailLineBreaks` and the private helpers it called,
/// as they were before the linear rewrite. Do not edit: it is the reference.
private enum LegacyUnwrap {

    private static let signatureDelimiterPattern = SignaturePatterns.delimiterLine

    private static let urlLeadingLineRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^(https?://|www\.)"#, options: [.caseInsensitive])
    }()

    private static let signOffWords: [String] = SignaturePatterns.signOffPhrases.sorted {
        $0.count == $1.count ? $0 < $1 : $0.count > $1.count
    }

    private static func startsWithURL(_ line: String) -> Bool {
        guard let regex = urlLeadingLineRegex else { return false }
        return regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func shouldPreserveLineBreakBetween(_ currentParagraph: String, and nextLine: String) -> Bool {
        guard let currentLine = currentParagraph
            .components(separatedBy: "\n")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              isStandaloneSignOffLine(currentLine),
              looksLikeNameLine(nextLine) else {
            return false
        }

        return true
    }

    private static func isStandaloneSignOffLine(_ line: String) -> Bool {
        let normalized = line
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)

        return signOffWords.contains(normalized)
    }

    private static func looksLikeNameLine(_ line: String) -> Bool {
        SignatureSignOffPolicy.looksLikeNameLine(line)
    }

    private static func isSignatureDelimiterLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let pattern = signatureDelimiterPattern else { return false }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        return pattern.firstMatch(in: trimmed, options: [], range: range) != nil
    }

    /// Unwraps artificial email line breaks (72-80 char wrapping) while preserving paragraph breaks
    /// Emails often contain hard line breaks at fixed widths for legacy compatibility.
    /// This function joins lines that were artificially wrapped while keeping intentional paragraph breaks.
    static func unwrap(_ text: String) -> String {
        var normalizedText = TextProcessing.normalizeLineEndings(text)

        // Normalize all special whitespace to regular space
        // This handles NBSP (U+00A0), thin space, em space, etc. that would otherwise
        // cause the lowercase check to fail when determining if lines should be joined
        let specialWhitespace: [Character] = [
            "\u{00A0}",  // Non-breaking space
            "\u{2002}",  // En space
            "\u{2003}",  // Em space
            "\u{2009}",  // Thin space
            "\u{200A}",  // Hair space
            "\u{202F}",  // Narrow no-break space
            "\u{205F}",  // Medium mathematical space
            "\u{3000}",  // Ideographic space
        ]
        for char in specialWhitespace {
            normalizedText = normalizedText.replacingOccurrences(of: String(char), with: " ")
        }

        let lines = normalizedText.components(separatedBy: "\n")
        guard lines.count > 1 else { return normalizedText }

        var result: [String] = []
        var currentParagraph = ""
        var i = 0

        while i < lines.count {
            let trimmedLine = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1

            // Skip empty lines but check if we should join across them
            if trimmedLine.isEmpty {
                if currentParagraph.isEmpty {
                    continue
                }

                // Look ahead to find the next non-empty line
                var nextNonEmptyIndex = i
                while nextNonEmptyIndex < lines.count &&
                      lines[nextNonEmptyIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                    nextNonEmptyIndex += 1
                }

                // Check if we should join across the blank line(s)
                if nextNonEmptyIndex < lines.count {
                    let nextLine = lines[nextNonEmptyIndex].trimmingCharacters(in: .whitespaces)
                    let currentIsSignatureDelimiter = isSignatureDelimiterLine(currentParagraph)
                    let nextIsSignatureDelimiter = isSignatureDelimiterLine(nextLine)
                    let lastChar = currentParagraph.last
                    let firstChar = nextLine.first

                    let endsWithPunctuation = lastChar.map { ".!?".contains($0) } ?? false
                    // Join unless next line starts with uppercase (new sentence)
                    let startsWithUppercase = firstChar?.isUppercase ?? false

                    if !endsWithPunctuation &&
                        !startsWithUppercase &&
                        !startsWithURL(nextLine) &&
                        !currentIsSignatureDelimiter &&
                        !nextIsSignatureDelimiter {
                        // This is a soft wrap across blank lines - skip the blanks and continue joining
                        continue
                    }
                }

                // Real paragraph break - flush current paragraph
                result.append(currentParagraph)
                result.append("") // Add paragraph separator
                currentParagraph = ""
                continue
            }

            if currentParagraph.isEmpty {
                currentParagraph = trimmedLine
            } else {
                if shouldPreserveLineBreakBetween(currentParagraph, and: trimmedLine) {
                    currentParagraph += "\n" + trimmedLine
                    continue
                }

                // Check if this looks like a continuation (soft wrap) or new paragraph
                let lastChar = currentParagraph.last
                let firstChar = trimmedLine.first

                let endsWithPunctuation = lastChar.map { ".!?".contains($0) } ?? false
                // Join unless next line starts with uppercase (new sentence)
                let startsWithUppercase = firstChar?.isUppercase ?? false

                // Don't join if current line ends with colon (often precedes lists)
                let endsWithColon = lastChar == ":"

                // Don't join if next line looks like a list item
                // Handles: 1. 10. 100. a) A. - * • · (a) (1)
                let isListItem = TextProcessing.isListItem(trimmedLine)
                let currentIsSignatureDelimiter = isSignatureDelimiterLine(currentParagraph)
                let nextIsSignatureDelimiter = isSignatureDelimiterLine(trimmedLine)

                if !endsWithPunctuation &&
                    !endsWithColon &&
                    !startsWithUppercase &&
                    !startsWithURL(trimmedLine) &&
                    !isListItem &&
                    !currentIsSignatureDelimiter &&
                    !nextIsSignatureDelimiter {
                    // Join with space (unwrap soft line break)
                    currentParagraph += " " + trimmedLine
                } else {
                    // New paragraph
                    result.append(currentParagraph)
                    currentParagraph = trimmedLine
                }
            }
        }

        if !currentParagraph.isEmpty {
            result.append(currentParagraph)
        }

        // Filter out empty strings and join with double newlines for paragraph breaks
        let paragraphs = result.filter { !$0.isEmpty }
        return paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
