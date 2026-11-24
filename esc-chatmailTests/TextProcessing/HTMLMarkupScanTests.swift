import XCTest
@testable import esc_chatmail

/// `HTMLMarkupScan` and `LineStartMarkerSearch` replace steps of text
/// derivation that were quadratic on markup a sender can write, and each must
/// give the result of what it replaced: the walk and the regexes are kept here
/// and compared with the scans over generated markup, then crafted shapes are
/// timed.
final class HTMLMarkupScanTests: XCTestCase {

    // MARK: - Same results

    func testContainsLikelyHTMLMarkup_matchesTheWalk() {
        var generator = MarkupGenerator(seed: 0xC0FFEE)
        for _ in 0..<30_000 {
            let html = generator.next()
            XCTAssertEqual(
                HTMLMarkupScan.containsLikelyHTMLMarkup(html),
                LegacyMarkupWalk.containsLikelyHTMLMarkup(html),
                html.debugDescription
            )
        }
    }

    func testBlockRules_matchTheirRegexes() throws {
        let rules: [(start: String, close: String, readsToTagEnd: Bool, options: NSRegularExpression.Options, regex: String)] = [
            ("<head\\b", "</head>", true, [.caseInsensitive], "<head\\b[^>]*>[\\s\\S]*?</head>"),
            ("<!--", "-->", false, [.caseInsensitive], "<!--[\\s\\S]*?-->"),
            ("<!--", "-->", false, [], "<!--[\\s\\S]*?-->"),
            ("<script", "</script>", true, [], "<script[^>]*>[\\s\\S]*?</script>"),
            ("<style", "</style>", true, [], "<style[^>]*>[\\s\\S]*?</style>"),
        ]
        var generator = MarkupGenerator(seed: 0xB10C)
        for rule in rules {
            let block = try XCTUnwrap(HTMLBlockRule(
                start: rule.start,
                close: rule.close,
                readsToTagEnd: rule.readsToTagEnd,
                options: rule.options
            ))
            let regex = try NSRegularExpression(pattern: rule.regex, options: rule.options)
            for _ in 0..<10_000 {
                let html = generator.next()
                XCTAssertEqual(block.removingBlocks(from: html), Self.replacing(regex, in: html, with: ""), "\(rule.regex) \(html.debugDescription)")
            }
        }
    }

    func testBreakPairs_matchTheRegex() throws {
        let regex = try NSRegularExpression(pattern: "<br[^>]*>\\s*<br[^>]*>", options: [])
        var generator = MarkupGenerator(seed: 0xB2)
        for _ in 0..<30_000 {
            let html = generator.next()
            XCTAssertEqual(
                HTMLMarkupScan.replacingBreakPairs(in: html, with: "\n\n"),
                Self.replacing(regex, in: html, with: "\n\n"),
                html.debugDescription
            )
        }
    }

    func testTagsEndingAtTagEnd_matchTheirRegexes() throws {
        for (pattern, template) in [
            ("<br[^>]*>", "\n"),
            ("<[^>]+>", ""),
            ("<[^>]+>", " "),
            ("</?(?:div|span|br|p|a|b|i|strong|em|font|blockquote)[^>]*>", ""),
        ] {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            var generator = MarkupGenerator(seed: 0x7A6)
            for _ in 0..<15_000 {
                let html = generator.next()
                XCTAssertEqual(
                    HTMLMarkupScan.replacingTagsEndingAtTagEnd(in: html, regex: regex, with: template),
                    Self.replacing(regex, in: html, with: template),
                    "\(pattern) \(html.debugDescription)"
                )
            }
        }
    }

    /// The regex `HTMLMarkupScan.removingHiddenElements` replaced.
    private static let hiddenElementRegex = try? NSRegularExpression(
        pattern: "<([a-zA-Z0-9]+)\\b[^>]*style\\s*=\\s*['\"][^'\"]*(?:display\\s*:\\s*none|visibility\\s*:\\s*hidden|mso-hide\\s*:\\s*all|max-height\\s*:\\s*0|opacity\\s*:\\s*0|font-size\\s*:\\s*0)[^'\"]*['\"][^>]*>[\\s\\S]*?</\\1>",
        options: [.caseInsensitive]
    )

    /// Characters whose full case folding the regex's backreference equated
    /// with ASCII letters, where the scan matches names ignoring ASCII case
    /// only (`testHiddenElements_fullCaseFoldedNames_areLeftInPlace`).
    private static let fullyFoldedScalars: Set<Unicode.Scalar> = [
        "\u{212A}", "\u{017F}", "\u{00DF}", "\u{1E9E}",
        "\u{FB00}", "\u{FB01}", "\u{FB02}", "\u{FB03}", "\u{FB04}", "\u{FB05}", "\u{FB06}",
    ]

    func testHiddenElements_matchTheRegex() throws {
        let regex = try XCTUnwrap(Self.hiddenElementRegex)
        var generator = MarkupGenerator(seed: 0x41DE)
        for _ in 0..<40_000 {
            let html = generator.next()
            if html.unicodeScalars.contains(where: Self.fullyFoldedScalars.contains) { continue }
            XCTAssertEqual(
                HTMLMarkupScan.removingHiddenElements(from: html),
                Self.replacing(regex, in: html, with: ""),
                html.debugDescription
            )
        }
    }

    /// The hidden-element regex picks the last hiding `style` whose end has a
    /// close tag after it; ends that cross a `>` in a value decide which.
    func testHiddenElements_crossingValues_matchTheRegex() throws {
        let regex = try XCTUnwrap(Self.hiddenElementRegex)
        let shapes = [
            "<div style=\"display:none\" x style='opacity:0 > </div> '>a</div>b</div>",
            "<div style='display:none'>a</DIV><div style=\"font-size:0\">b</div>c",
            "<p style=\"display:none>\" style='opacity:0'>x</p>y</p>",
            "<span style = \"mso-hide:all\">x</Span><span>y</span>",
            "<td style=\"max-height:0\" style=\"display:none\">x</td>",
            "<div style=\"display:none\">x",
            "<kbd style=\"display:none\">x</KBD>",
        ]
        for html in shapes {
            XCTAssertEqual(HTMLMarkupScan.removingHiddenElements(from: html), Self.replacing(regex, in: html, with: ""), html)
        }
    }

    /// `HTMLMeaningfulContentChecker`'s three hidden-element regexes, which
    /// `HiddenElementRule.meaningfulContentRules` replaced, in order.
    private static let meaningfulContentHiddenRegexes: [NSRegularExpression] = [
        "<([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*\\bhidden\\b[^>]*>[\\s\\S]*?</\\1>",
        "<([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*style\\s*=\\s*['\"][^'\"]*(?:display\\s*:\\s*none|visibility\\s*:\\s*hidden|mso-hide\\s*:\\s*all|opacity\\s*:\\s*0(?:\\.0+)?)[^'\"]*['\"][^>]*>[\\s\\S]*?</\\1>",
        "<([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*class\\s*=\\s*['\"][^'\"]*(?:\\bm-hide\\b|\\bpreheader\\b|\\bpreview-text\\b)[^'\"]*['\"][^>]*>[\\s\\S]*?</\\1>",
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    func testMeaningfulContentHiddenRules_matchTheirRegexes() throws {
        let rules = HiddenElementRule.meaningfulContentRules
        XCTAssertEqual(rules.count, 3)
        XCTAssertEqual(Self.meaningfulContentHiddenRegexes.count, 3)
        for (rule, regex) in zip(rules, Self.meaningfulContentHiddenRegexes) {
            var generator = MarkupGenerator(seed: 0xC4EC)
            for _ in 0..<25_000 {
                let html = generator.next()
                if html.unicodeScalars.contains(where: Self.fullyFoldedScalars.contains) { continue }
                XCTAssertEqual(rule.removing(from: html), Self.replacing(regex, in: html, with: ""), "\(regex.pattern) \(html.debugDescription)")
            }
        }
    }

    /// SwiftSoup writes `<` and `>` in attribute values back out as they came,
    /// so markup a sender hides in one attribute reaches the meaningful-content
    /// check after every cleanup mode, and the rich-content pre-run's Apple
    /// rich-link pass on every received message. At these sizes the regexes
    /// and the `<div` search took 4 to 16 s (-O).
    /// Revert-check: `HiddenElementRule.meaningfulContentRules` and the two
    /// `HTMLBlockRule`s in `HTMLMeaningfulContentChecker.stripNonRenderableContent`,
    /// and the kept hits in `RichContentClassifier.findMatchingClosingDiv`.
    func testMarkupHiddenInAnAttribute_isReadOnce() {
        let shapes = [
            "<p title=\"" + String(repeating: "<!--", count: 20_000) + "\">Hello there</p>",
            "<p title=\"" + String(repeating: "<head>", count: 20_000) + "\">Hello there</p>",
            "<img title=\"" + String(repeating: "<a style='display:none'>", count: 10_000) + "\">Hello",
            "<img title=\"" + String(repeating: "<a hidden>", count: 20_000) + "\">Hello",
            "<img title=\"" + String(repeating: "<a class='preheader'>", count: 10_000) + "\">Hello",
            "<div class=\"apple-rich-link\" title=\"" + String(repeating: "<div", count: 20_000) + "\">Hello there.</div>",
        ]
        for html in shapes {
            let started = Date()
            _ = HTMLMeaningfulContentChecker.hasMeaningfulContent(html)
            _ = RichContentClassifier.hasGenuineRichContent(html)
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, String(html.prefix(40)))
        }
    }

    /// The one deliberate difference: a name meets its close tag ignoring
    /// ASCII case only, where the regex's backreference folded case fully.
    /// Revert-check: none; this pins the documented difference in
    /// `HTMLMarkupScan.removingHiddenElements`, which a return to the regex for
    /// such names would undo (and make quadratic again).
    func testHiddenElements_fullCaseFoldedNames_areLeftInPlace() throws {
        let regex = try XCTUnwrap(Self.hiddenElementRegex)
        for html in [
            "<ss style=\"display:none\">hidden</ß>visible",
            "<st style=\"display:none\">hidden</\u{FB06}>visible",
            "<kbd style=\"display:none\">hidden</\u{212A}BD>visible",
            "<div\u{212A} style=\"display:none\">hidden</div\u{212A}>visible",
        ] {
            XCTAssertEqual(Self.replacing(regex, in: html, with: ""), "visible", html)
            XCTAssertEqual(HTMLMarkupScan.removingHiddenElements(from: html), html, html)
        }
    }

    // MARK: - Linear where the first scans were not (review round 1)

    /// Thousands of close tags before one `>`: the walk jumps past it once.
    /// Revert-check: the binary search for the next close tag in
    /// `HTMLMarkupScan.CloseTagIndex.answers` (a walk over the tags before the
    /// `>` took 42 s at this size in Debug).
    func testCloseTagsSharingOneTagEnd_areReadOnce() {
        let small = "<x>" + String(repeating: "</x a", count: 2_000) + ">"
        XCTAssertEqual(
            HTMLMarkupScan.containsLikelyHTMLMarkup(small),
            LegacyMarkupWalk.containsLikelyHTMLMarkup(small)
        )
        let html = "<x>" + String(repeating: "</x a", count: 100_000) + ">"
        let started = Date()
        _ = HTMLMarkupScan.containsLikelyHTMLMarkup(html)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// Thousands of spellings of one folded name (`s` and `ſ`) share answers.
    /// Revert-check: the folded-key cache in `HTMLMarkupScan.CloseTagIndex`
    /// (answers kept by name refilter the key's close tags for each spelling).
    func testNamesThatFoldAlike_shareTheirAnswers() {
        var html = String(repeating: "</sssssssssssss>", count: 20_000)
        for bits in 0..<8_192 {
            html += "<" + String((0..<13).map { bits >> $0 & 1 == 0 ? "s" : "\u{017F}" }) + ">"
        }
        let started = Date()
        XCTAssertFalse(HTMLMarkupScan.containsLikelyHTMLMarkup(html))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// One close tag with a name outside ASCII must not slow every element.
    /// Revert-check: handing such names to the regex in
    /// `HTMLMarkupScan.removingHiddenElements` (24.7 s at this size, -O).
    func testHiddenElements_aNameOutsideASCII_keepsTheScanLinear() {
        let html = "</\u{212A}>" + String(repeating: "<div style=\"display:none\">x", count: 8_000)
        let started = Date()
        _ = HTMLMarkupScan.removingHiddenElements(from: html)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testLineStartMarkers_matchTheirRegexes() throws {
        let markers = [
            "On .{1,400}? wrote:",
            "On [A-Z][a-z]+ \\d{1,2}, \\d{4} at \\d{1,2}:\\d{2}\\s*[AP]M,",
            "-{2,}\\s*Original Message\\s*-{2,}",
            "(?:Le|Am)\\s.{1,200}?\\s(?:a écrit|schrieb):",
        ]
        let regexes = try markers.map {
            try NSRegularExpression(pattern: "(?:^|[\\r\\n])\\s*" + $0, options: [.caseInsensitive])
        }
        let search = LineStartMarkerSearch(markers: markers)
        var generator = MarkupGenerator(seed: 0x11E5)
        for _ in 0..<30_000 {
            let text = generator.next()
            let range = NSRange(location: 0, length: (text as NSString).length)
            let matches: [NSRange] = regexes.compactMap { regex -> NSRange? in
                regex.firstMatch(in: text, options: [], range: range)?.range
            }
            let expected: NSRange? = matches.min(by: Self.isEarlier)
            XCTAssertEqual(search.earliestMatch(in: text), expected, text.debugDescription)
        }
    }

    func testLineBreakRuns_matchTheRegex() throws {
        let regex = try NSRegularExpression(pattern: "(\\s*\\n\\s*){2,}", options: [])
        let pieces = [" ", "\t", "\n", "\n", "\r", "\r\n", "\u{A0}", "\u{2028}", "\u{2029}", "\u{85}", "\u{3000}", "\u{B}", "\u{C}",
                      "a", "b", "\u{301}", "\u{1F600}", "<", ">"]
        var state: UInt64 = 0x5EED
        for _ in 0..<30_000 {
            var text = ""
            for _ in 0..<Int(Self.splitMix(&state) % 24) {
                text += pieces[Int(Self.splitMix(&state) % UInt64(pieces.count))]
            }
            XCTAssertEqual(
                HTMLMarkupScan.collapsingLineBreakRuns(in: text),
                Self.replacing(regex, in: text, with: "\n\n"),
                text.debugDescription
            )
        }
    }

    /// The regex tried every split of a run between its nested `\s*`: 1,600
    /// no-break spaces around one newline took 69 s, and `[ \t]+` ahead of it
    /// leaves them (`&nbsp;` decodes to them).
    /// Revert-check: `HTMLMarkupScan.collapsingLineBreakRuns` in
    /// `TextProcessing.normalizingWhitespace` (the regex then runs for minutes).
    func testNoBreakSpaceRuns_normalizeQuickly() {
        let run = String(repeating: "\u{A0}", count: 20_000)
        let started = Date()
        _ = TextProcessing.extractPlainText(from: "a" + run + "\n" + run + "b")
        _ = TextProcessing.extractPlainText(from: "a" + run + "\n" + run + "b<x")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: - Linear on crafted markup

    /// Each of these held a message's ingest for seconds to tens of seconds
    /// at a quarter of this size, and the time grew with the square of the size.
    /// Revert-check: `HTMLMarkupScan.containsLikelyHTMLMarkup`,
    /// `replacingBlocks`, `replacingTagsEndingAtTagEnd` and
    /// `removingHiddenElements` (each in its caller), and
    /// `LineStartMarkerSearch` in `EmailDOMQuoteRemover+TextMarkers`: put back
    /// one walk or regex and its input here runs past the limit.
    func testCraftedMarkup_ingestsQuickly() async throws {
        let count = 30_000
        let bodies = [
            String(repeating: "<head>x", count: count),
            String(repeating: "<!--x", count: count),
            String(repeating: "<script>x", count: count),
            String(repeating: "<style>x", count: count),
            String(repeating: "<foo>x", count: count),
            String(repeating: "<div style=\"a", count: count),
            "<p>a" + String(repeating: " \n ", count: count) + "b</p>",
        ]
        for body in bodies {
            let started = Date()
            _ = try await MessageProcessor().processGmailMessage(Self.message(html: body), myAliases: [])
            let elapsed = Date().timeIntervalSince(started)
            print(String(format: "crafted ingest %.2f s: %@", elapsed, String(body.prefix(12))))
            XCTAssertLessThan(elapsed, 10, String(body.prefix(40)))
        }
    }

    /// A tag start with no `>` after it sends `extractPlainText` to its regex
    /// recovery, never a parse, and each of the recovery's rules read to the
    /// end of the text from every start these repeat.
    /// Revert-check: `malformedHTMLBlockRules` (each of its four rules),
    /// `replacingBreakPairs` and `replacingTagsEndingAtTagEnd` (both of its
    /// calls) in `TextProcessing.recoverPlainTextFromMalformedHTML`.
    func testCraftedTagStarts_extractQuickly() {
        let count = 40_000
        let unclosed = "<a"
        for text in [
            String(repeating: "<br", count: count),
            String(repeating: "<x", count: count),
            String(repeating: "<head>x", count: count / 2) + unclosed,
            String(repeating: "<!--x", count: count / 2) + unclosed,
            String(repeating: "<script>x", count: count / 2) + unclosed,
            String(repeating: "<style>x", count: count / 2) + unclosed,
        ] {
            let started = Date()
            _ = TextProcessing.extractPlainText(from: text)
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, String(text.prefix(6)))
        }
    }

    // MARK: - Helpers

    /// The order `earliestTextMarkerMatch` took the first match of each regex in.
    private static func isEarlier(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        if lhs.location == rhs.location {
            return lhs.length < rhs.length
        }
        return lhs.location < rhs.location
    }

    /// SplitMix64.
    private static func splitMix(_ state: inout UInt64) -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template
        )
    }

    private static func message(html: String) -> GmailMessage {
        GmailMessage(
            id: "crafted",
            threadId: "crafted-thread",
            labelIds: ["INBOX"],
            snippet: "crafted",
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
    }
}

/// Markup soup from the pieces the replaced steps look at.
private struct MarkupGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    private static let pieces: [String] = [
        "<", ">", "\"", "'", "/", "!", "-", "--", "=", " ", "  ", "\n", "\r", "\r\n", "\t", "\u{00A0}", "\u{2028}",
        "a", "x", "K", "\u{212A}", "ß", "é", "e\u{301}", ">\u{301}", "\u{1F600}",
        "<!--", "-->", "<!-->", "<!doctype html>", "<!DOCTYPE", "<!x>",
        "<head", "<head>", "<HEAD x>", "<header>", "</head>", "</HEAD>", "</head >",
        "<script", "<script>", "</script>", "</SCRIPT>", "<style", "<style>", "</style>",
        "<br", "<br>", "<br/>", "<BR>", "<br x=\">\">",
        "<div", "<div>", "</div>", "</DIV>", "<div ", "<foo", "<foo>", "</foo>", "</foo >", "</foo x>", "</FOO>",
        "<x", "<x>", "</x>", "<a1>", "</a1>", "<p>", "</p>", "<kbd>", "</\u{212A}bd>",
        "style", "style=", "style=\"", "style='", " style=\"display:none\"", " style='opacity:0'",
        "display:none", "display : none", "font-size:0", "mso-hide:all", "visibility:hidden", "max-height:0",
        "opacity:0.00", " hidden", "hidden>", "Hidden", "class=", " class=\"preheader\"", " class='m-hide x'", "preview-text", "<a1 ",
        "On ", "on ", " wrote:", "On Jan 30, 2026 at 7:32 PM,", "Le ", " a écrit:", "Am ", " schrieb:",
        "-----Original Message-----", "-- Original Message --",
    ]

    mutating func next() -> String {
        let length = Int(random() % 40)
        var text = ""
        for _ in 0..<length {
            text += Self.pieces[Int(random() % UInt64(Self.pieces.count))]
        }
        return text
    }

    /// SplitMix64.
    private mutating func random() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `TextProcessing.containsLikelyHTMLMarkup` as it was: from each `<`, a walk
/// to the tag's `>`, and for an unknown tag a walk to the end of the text for
/// its close tag.
private enum LegacyMarkupWalk {
    static func containsLikelyHTMLMarkup(_ html: String) -> Bool {
        var index = html.startIndex

        while let tagStart = html[index...].firstIndex(of: "<") {
            let nextIndex = html.index(after: tagStart)
            guard nextIndex < html.endIndex else { return false }

            let firstCharacter = html[nextIndex]
            if firstCharacter.isLetter,
               let tagEnd = tagEndIndex(in: html, from: nextIndex) {
                let tagNameStart = nextIndex
                var tagNameEnd = tagNameStart
                while tagNameEnd < html.endIndex, TextProcessing.isTagNameCharacter(html[tagNameEnd]) {
                    tagNameEnd = html.index(after: tagNameEnd)
                }

                let tagName = String(html[tagNameStart..<tagNameEnd]).lowercased()
                if TextProcessing.knownHTMLTagNames.contains(tagName) ||
                    TextProcessing.tagHasAttributes(in: html, nameEnd: tagNameEnd, tagEnd: tagEnd) ||
                    hasExplicitCloseTag(named: tagName, in: html, after: html.index(after: tagEnd)) {
                    return true
                }
            } else if firstCharacter == "!",
                      html[nextIndex...].lowercased().hasPrefix("!doctype"),
                      tagEndIndex(in: html, from: nextIndex) != nil {
                return true
            }
            if firstCharacter == "!",
               html[nextIndex...].hasPrefix("!--"),
               html[nextIndex...].range(of: "-->") != nil {
                return true
            }

            if firstCharacter == "/" {
                let nameStart = html.index(after: nextIndex)
                var nameEnd = nameStart
                while nameEnd < html.endIndex, TextProcessing.isTagNameCharacter(html[nameEnd]) {
                    nameEnd = html.index(after: nameEnd)
                }

                let tagName = String(html[nameStart..<nameEnd]).lowercased()
                if nameStart < html.endIndex,
                   html[nameStart].isLetter,
                   TextProcessing.knownHTMLTagNames.contains(tagName),
                   tagEndIndex(in: html, from: nameEnd) != nil {
                    return true
                }
            }

            index = nextIndex
        }

        return false
    }

    private static func tagEndIndex(in html: String, from startIndex: String.Index) -> String.Index? {
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

    private static func hasExplicitCloseTag(
        named tagName: String,
        in html: String,
        after startIndex: String.Index
    ) -> Bool {
        var index = startIndex

        while let tagStart = html[index...].firstIndex(of: "<") {
            let afterOpen = html.index(after: tagStart)
            guard afterOpen < html.endIndex else { return false }

            guard html[afterOpen] == "/" else {
                index = afterOpen
                continue
            }

            let nameStart = html.index(after: afterOpen)
            var nameEnd = nameStart
            while nameEnd < html.endIndex, TextProcessing.isTagNameCharacter(html[nameEnd]) {
                nameEnd = html.index(after: nameEnd)
            }

            guard String(html[nameStart..<nameEnd]).caseInsensitiveCompare(tagName) == .orderedSame,
                  let tagEnd = tagEndIndex(in: html, from: nameEnd) else {
                index = nameEnd
                continue
            }

            var closeRemainder = nameEnd
            while closeRemainder < tagEnd, html[closeRemainder].isWhitespace {
                closeRemainder = html.index(after: closeRemainder)
            }

            if closeRemainder == tagEnd {
                return true
            }

            index = html.index(after: tagEnd)
        }

        return false
    }
}
