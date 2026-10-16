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
