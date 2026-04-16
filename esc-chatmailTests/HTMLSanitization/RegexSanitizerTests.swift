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
