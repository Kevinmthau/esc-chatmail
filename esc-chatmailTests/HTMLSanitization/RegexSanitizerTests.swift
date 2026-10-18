import XCTest
@testable import esc_chatmail

final class RegexSanitizerTests: XCTestCase {

    // MARK: - replace(pattern:)

    func testReplace_patternBased_replacesAllMatches() {
        let input = "foo bar FOO BAR"
        let result = RegexSanitizer.replace(in: input, pattern: "foo", with: "X")
        XCTAssertEqual(result, "X bar X BAR")
    }

    func testReplace_patternBased_caseSensitiveOption() {
        let input = "Foo FOO"
        let result = RegexSanitizer.replace(
            in: input,
            pattern: "Foo",
            with: "X",
            options: [.regularExpression] // no case-insensitive flag
        )
        XCTAssertEqual(result, "X FOO")
    }

    func testReplace_patternBased_emptyReplacement_removesMatches() {
        let input = "javascript:alert(1); color: red;"
        let result = RegexSanitizer.replace(in: input, pattern: "javascript:")
        XCTAssertFalse(result.contains("javascript:"))
        XCTAssertTrue(result.contains("color: red"))
    }

    // MARK: - replace(regex:)

    func testReplace_compiledRegex_replacesMatches() throws {
        let regex = try NSRegularExpression(pattern: "\\d+", options: [])
        let result = RegexSanitizer.replace(in: "abc 123 def 456", regex: regex, with: "N")
        XCTAssertEqual(result, "abc N def N")
    }

    // MARK: - replace(regex:) with an optional regex

    func testReplace_optionalCompiledRegex_nil_returnsInputUnchanged() {
        let regex: NSRegularExpression? = nil
        XCTAssertEqual(RegexSanitizer.replace(in: "a  b", regex: regex, with: " "), "a  b")
    }

    func testReplace_optionalCompiledRegex_nonNil_replacesMatches() throws {
        let regex: NSRegularExpression? = try NSRegularExpression(pattern: "\\d+", options: [])
        XCTAssertEqual(RegexSanitizer.replace(in: "abc 123 def 456", regex: regex, with: "N"), "abc N def N")
    }

    // MARK: - whitespaceRunRegex

    /// The shared `\s+` constant replaced five identical per-type copies; it
    /// must stay options-free (ICU `\s`, case-sensitive) so their callers keep
    /// collapsing the same characters to the literal " ".
    func testWhitespaceRunRegex_optionsFree_collapsesICUWhitespaceRunsToSingleSpace() throws {
        let regex = try XCTUnwrap(RegexSanitizer.whitespaceRunRegex)
        XCTAssertEqual(regex.pattern, "\\s+")
        XCTAssertEqual(regex.options, [])
        XCTAssertEqual(
            RegexSanitizer.replace(in: "a \t\n\u{00A0}b   c", regex: RegexSanitizer.whitespaceRunRegex, with: " "),
            "a b c"
        )
    }

    /// The call sites that swapped `replacingOccurrences(of: "\\s+", with: " ",
    /// options: .regularExpression)` for the shared constant did so on the
    /// premise that the two forms are byte-identical: same ICU `\s` class,
    /// same literal template, full-string range. This pins that premise on
    /// the C0 whitespace controls, NEL, NBSP, the Unicode space separators and
    /// the line and paragraph separators, whichever of them ICU's `\s` admits,
    /// and on a non-`\s` format character (ZWSP) that both forms leave alone.
    /// HONEST SCOPE: it cannot detect a call site reverting to the per-call
    /// form, whose output is identical by construction.
    func testWhitespaceRunRegex_perCallReplacingOccurrencesInput_producesIdenticalOutput() {
        let input = "a \t\u{000B}\u{000C}\r\n\u{0085}\u{00A0}\u{1680}\u{2000}\u{2007}"
            + "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}b\u{200B}c \n"
        let perCall = input.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let shared = RegexSanitizer.replace(in: input, regex: RegexSanitizer.whitespaceRunRegex, with: " ")

        XCTAssertEqual(shared, perCall)
        XCTAssertNotEqual(shared, input)
        XCTAssertEqual(
            RegexSanitizer.replace(
                in: "a\u{00A0}\u{2028}\u{2029}\u{3000}b\u{200B}c",
                regex: RegexSanitizer.whitespaceRunRegex,
                with: " "
            ),
            "a b\u{200B}c"
        )
    }

    /// The two plain-text fallbacks (`HTMLContentLoader.hasMeaningfulPlainText`,
    /// `CanonicalEmailContentLoader.normalizedMeaningfulPlainText`) strip `\s+`
    /// to `""` to ask whether any non-whitespace survives. They moved from the
    /// per-call `replacingOccurrences(of: "\\s+", with: "", options:
    /// .regularExpression)` onto the shared constant on the same premise as the
    /// `" "` callers: the template is the caller's, the `\s` class is shared.
    /// This pins that premise with the empty template over the same ICU
    /// whitespace inventory, including the all-whitespace input those callers
    /// treat as "no content" and a ZWSP-only input they still count as content.
    /// HONEST SCOPE: it cannot detect a call site reverting to the per-call
    /// form, whose output is identical by construction.
    func testWhitespaceRunRegex_emptyTemplate_perCallReplacingOccurrencesInput_producesIdenticalOutput() {
        let mixed = "a \t\u{000B}\u{000C}\r\n\u{0085}\u{00A0}\u{1680}\u{2000}\u{2007}"
            + "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}b\u{200B}c \n"
        let whitespaceOnly = " \t\u{000B}\u{000C}\r\n\u{0085}\u{00A0}\u{1680}\u{2000}\u{2007}"
            + "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}"

        for input in [mixed, whitespaceOnly, "\u{200B}", ""] {
            let perCall = input.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            let shared = RegexSanitizer.replace(in: input, regex: RegexSanitizer.whitespaceRunRegex, with: "")
            XCTAssertEqual(shared, perCall, "input: \(input.unicodeScalars.map { String($0.value, radix: 16) })")
        }

        XCTAssertEqual(RegexSanitizer.replace(in: mixed, regex: RegexSanitizer.whitespaceRunRegex, with: ""), "ab\u{200B}c")
        XCTAssertEqual(RegexSanitizer.replace(in: whitespaceOnly, regex: RegexSanitizer.whitespaceRunRegex, with: ""), "")
        XCTAssertEqual(RegexSanitizer.replace(in: "\u{200B}", regex: RegexSanitizer.whitespaceRunRegex, with: ""), "\u{200B}")
    }

    /// `EmailDOMQuoteRemover.normalizedVisibleLineText` used to swap U+00A0 for
    /// a space before the collapse. ICU `\s` includes `\p{Z}`, so the NBSP is
    /// already part of every run the collapse replaces, and the trailing
    /// `.whitespacesAndNewlines` trim removes a leading or trailing NBSP just
    /// as it removes the space the pre-pass would have left. This pins that a
    /// pre-passed input and the raw input collapse (and trim) to the same
    /// string wherever the NBSP sits: alone, leading, trailing, between words,
    /// inside a mixed run, or beside a combining mark.
    /// HONEST SCOPE: re-adding the pre-pass is output-identical by
    /// construction, so this pins the premise rather than the call site.
    func testWhitespaceRunRegex_nbspPrePass_isSubsumedByCollapseAndTrim() {
        let inputs = [
            "\u{00A0}",
            "\u{00A0}\u{00A0}a",
            "a\u{00A0}\u{00A0}",
            "a\u{00A0}b",
            "a\u{00A0}\u{00A0}b",
            "a \u{00A0}\t\n\u{00A0} b",
            "a\u{00A0}\u{0301}b",
            "\u{00A0}a\u{00A0}b\u{00A0}",
        ]

        for input in inputs {
            let prePassed = input.replacingOccurrences(of: "\u{00a0}", with: " ")
            let viaPrePass = RegexSanitizer.replace(in: prePassed, regex: RegexSanitizer.whitespaceRunRegex, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let direct = RegexSanitizer.replace(in: input, regex: RegexSanitizer.whitespaceRunRegex, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(direct, viaPrePass, "input: \(input.unicodeScalars.map { String($0.value, radix: 16) })")
        }

        XCTAssertEqual(
            RegexSanitizer.replace(in: "\u{00A0}a \u{00A0}\t\u{00A0} b\u{00A0}", regex: RegexSanitizer.whitespaceRunRegex, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "a b"
        )
    }

    // MARK: - applyRules

    func testApplyRules_stringRules_appliedInOrder() {
        let rules: [(String, String)] = [
            ("foo", "bar"),
            ("bar", "baz")
        ]
        // First rule turns "foo" into "bar", second rule then turns all "bar" into "baz"
        let result = RegexSanitizer.applyRules(to: "foo bar", rules: rules)
        XCTAssertEqual(result, "baz baz")
    }

    func testApplyRules_stringRules_emptyRulesArray_returnsInputUnchanged() {
        let result = RegexSanitizer.applyRules(to: "hello", rules: [])
        XCTAssertEqual(result, "hello")
    }

    func testApplyRules_compiledRegexRules_appliedInOrder() throws {
        let regex1 = try NSRegularExpression(pattern: "\\d+", options: [])
        let regex2 = try NSRegularExpression(pattern: "[A-Z]+", options: [])
        let rules: [(regex: NSRegularExpression, replacement: String)] = [
            (regex1, "#"),
            (regex2, "x")
        ]
        let result = RegexSanitizer.applyRules(to: "ABC 123 DEF", compiledRules: rules)
        XCTAssertEqual(result, "x # x")
    }

    // MARK: - removeTags

    func testRemoveTags_singleTagWithContent_removesEntirely() {
        let html = "<p>before</p><script>alert(1)</script><p>after</p>"
        let result = RegexSanitizer.removeTags(from: html, tags: ["script"])
        XCTAssertFalse(result.contains("<script"))
        XCTAssertFalse(result.contains("alert"))
        XCTAssertTrue(result.contains("<p>before</p>"))
        XCTAssertTrue(result.contains("<p>after</p>"))
    }

    func testRemoveTags_selfClosingTag_removed() {
        let html = "<p>x</p><script src=\"bad.js\" /><p>y</p>"
        let result = RegexSanitizer.removeTags(from: html, tags: ["script"])
        XCTAssertFalse(result.contains("<script"))
        XCTAssertFalse(result.contains("bad.js"))
    }

    func testRemoveTags_multilineContent_removed() {
        let html = "<p>a</p><script>\nvar x = 1;\nalert(x);\n</script><p>b</p>"
        let result = RegexSanitizer.removeTags(from: html, tags: ["script"])
        XCTAssertFalse(result.contains("<script"))
        XCTAssertFalse(result.contains("alert"))
    }

    func testRemoveTags_multipleTagNames_allRemoved() {
        let html = "<p>ok</p><script>bad</script><iframe src=\"x\"></iframe><object>z</object>"
        let result = RegexSanitizer.removeTags(from: html, tags: ["script", "iframe", "object"])
        XCTAssertFalse(result.contains("<script"))
        XCTAssertFalse(result.contains("<iframe"))
        XCTAssertFalse(result.contains("<object"))
        XCTAssertTrue(result.contains("<p>ok</p>"))
    }

    func testRemoveTags_caseInsensitive_uppercaseTagsAlsoRemoved() {
        let html = "<P>ok</P><SCRIPT>x</SCRIPT>"
        let result = RegexSanitizer.removeTags(from: html, tags: ["script"])
        XCTAssertFalse(result.uppercased().contains("<SCRIPT"))
    }

    // MARK: - compileTagPattern

    func testCompileTagPattern_returnsNonNilForValidTag() {
        XCTAssertNotNil(RegexSanitizer.compileTagPattern("script"))
    }

    func testCompileTagPattern_precompiledMatchesExpectedPattern() {
        let regex = RegexSanitizer.compileTagPattern("style")
        XCTAssertNotNil(regex)

        let html = "<style>.x { color: red; }</style>"
        let result = RegexSanitizer.replace(in: html, regex: regex!)
        XCTAssertEqual(result, "")
    }

    // MARK: - removeTags with pre-compiled patterns

    func testRemoveTags_precompiledPatterns_matchesPathBehavior() throws {
        let patterns = [RegexSanitizer.compileTagPattern("script")!]
        let html = "<p>a</p><script>alert(1)</script><p>b</p>"
        let result = RegexSanitizer.removeTags(from: html, compiledPatterns: patterns)
        XCTAssertFalse(result.contains("<script"))
        XCTAssertTrue(result.contains("<p>a</p>"))
        XCTAssertTrue(result.contains("<p>b</p>"))
    }
}
