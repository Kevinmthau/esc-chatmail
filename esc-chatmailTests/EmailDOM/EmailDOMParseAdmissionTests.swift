import XCTest
import SwiftSoup
@testable import esc_chatmail

/// `EmailDOMParseAdmission`: HTML nested past the limit never reaches the
/// app's DOM code, nothing deep is built or released on the caller's stack,
/// every caller's own failure branch then runs, and the byte scan's bound is
/// never below the depth SwiftSoup really builds.
final class EmailDOMParseAdmissionTests: XCTestCase {

    // MARK: - Deep bodies are refused before parsing

    private static let deepLevels = 50_000
    private static let sentinel = "deep-sentinel-text"

    private static var deepDivNest: String {
        String(repeating: "<div>", count: deepLevels) + sentinel + String(repeating: "</div>", count: deepLevels)
    }

    /// Each shape nests one level per repetition in SwiftSoup's tree.
    private static var deepShapes: [(name: String, html: String)] {
        [
            ("div nest", deepDivNest),
            ("unclosed span", String(repeating: "<span>", count: deepLevels) + sentinel),
            ("table cells", String(repeating: "<table><td>", count: deepLevels / 4) + sentinel),
            // The tree builder reconstructs each unclosed <b> inside the next
            // line's text, so this nests one level per line.
            ("formatting staircase", String(repeating: "<p><b>x</p>\n", count: deepLevels) + sentinel),
            ("document wrapper", "<!DOCTYPE html><html><head><title>t</title></head><body>" + deepDivNest + "</body></html>"),
        ]
    }

    /// Past `maximumBoundForMeasuredParse` the scan's bound refuses the body
    /// unparsed: the refusal carries that bound, not a measured depth.
    /// Revert-check: the `bound > maximumBoundForMeasuredParse` refusal in
    /// `EmailDOMParseAdmission.admittedParse` (without it these are parsed on
    /// the measuring thread, the table nest for minutes, and the refusal
    /// carries the measured depth).
    func testParseDocument_deepNest_isRefusedBeforeParsing() {
        for shape in Self.deepShapes {
            let bound = EmailDOMParseAdmission.estimatedDepth(
                of: shape.html,
                limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse
            )
            XCTAssertGreaterThan(bound, EmailDOMParseAdmission.maximumBoundForMeasuredParse, shape.name)
            XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(shape.html), shape.name) { error in
                XCTAssertEqual(
                    error as? EmailDOMParseRefusal,
                    .nestingTooDeep(depth: bound, limit: EmailDOMParseAdmission.maximumDepth),
                    shape.name
                )
            }
        }
    }

    // MARK: - Between the bounds the real depth decides

    /// Optional end tags left out (`<ul><li>a</ul>`) keep the scan from
    /// closing what the tree builder closes, so the bound passes the limit
    /// for a shallow tree; the measured parse admits it.
    func testParseDocument_overCountedShallowBody_isAdmittedByTheMeasuredParse() throws {
        let html = String(repeating: "<div><ul><li>a<li>b</ul><table><tr><td><font>x</td></tr></table></div>", count: 200)
        XCTAssertGreaterThan(EmailDOMParseAdmission.estimatedDepth(of: html), EmailDOMParseAdmission.maximumDepth)

        let document = try EmailDOMParseAdmission.parseDocument(html)
        XCTAssertLessThan(EmailDOMParseAdmission.measuredDepth(of: [document], rootDepth: 1), 20)
        XCTAssertEqual(try document.select("li").count, 400)
    }

    /// A tree past the limit but within the measured parse's bound is built,
    /// measured and released on the measuring thread, never on the caller's.
    /// Revert-check: `EmailDOMParseAdmission.runOnMeasuringThread` (running
    /// its work on the caller's 512 KB thread instead releases 1,500 levels
    /// there and crashes the test host rather than failing an assertion;
    /// checked once, on purpose).
    func testParseDocument_1500DeepNest_isMeasuredAndReleasedOffTheCallersStack() {
        let html = String(repeating: "<div>", count: 1_500) + Self.sentinel
        let bound = EmailDOMParseAdmission.estimatedDepth(of: html)
        XCTAssertGreaterThan(bound, EmailDOMParseAdmission.maximumDepth)
        XCTAssertLessThanOrEqual(bound, EmailDOMParseAdmission.maximumBoundForMeasuredParse)

        let done = expectation(description: "parse on a 512 KB thread")
        let results = LockedResults()
        let thread = Thread {
            do {
                _ = try EmailDOMParseAdmission.parseDocument(html)
            } catch {
                results.error = error as? EmailDOMParseRefusal
            }
            results.text = TextProcessing.extractPlainText(from: html)
            done.fulfill()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        wait(for: [done], timeout: 120)

        XCTAssertEqual(results.error, .nestingTooDeep(depth: 1_500 + 4, limit: EmailDOMParseAdmission.maximumDepth))
        XCTAssertEqual(results.text.map { $0.contains(Self.sentinel) }, true)
    }

    func testMeasuredDepth_countsNodesFromTheRoot() throws {
        let document = try XCTUnwrap(SwiftSoup.parse("<div><p><b>x</b></p></div><span>y</span>"))
        // document, html, body, div, p, b, text
        XCTAssertEqual(EmailDOMParseAdmission.measuredDepth(of: [document], rootDepth: 1), 7)
    }

    func testParseBodyFragmentAndFragmentParser_deepNest_areRefused() {
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseBodyFragment(Self.deepDivNest))
        XCTAssertThrowsError(try EmailDOMFragmentParser.parse(Self.deepDivNest, inputIsFragment: true))
        XCTAssertThrowsError(try EmailDOMFragmentParser.parse(Self.deepDivNest, inputIsFragment: false))
        // A table-section fragment goes through the context parse.
        let rows = "<tr>" + String(repeating: "<td><table><tr>", count: Self.deepLevels / 4) + "</tr>"
        XCTAssertThrowsError(try EmailDOMFragmentParser.parse(rows, inputIsFragment: true))
    }

    func testEmailDocument_deepNest_throwsAndTryParseReturnsNil() {
        XCTAssertThrowsError(try EmailDocument.parse(Self.deepDivNest))
        XCTAssertNil(EmailDocument.tryParse(Self.deepDivNest))
    }

    // MARK: - Each caller's failure branch runs

    func testExtractPlainText_deepNest_recoversTextWithoutTheDOM() {
        let text = TextProcessing.extractPlainText(from: Self.deepDivNest)
        XCTAssertTrue(text.contains(Self.sentinel))
    }

    func testQuoteRemover_deepNest_returnsItsInput() {
        XCTAssertEqual(EmailDOMQuoteRemover.removeQuotes(from: Self.deepDivNest), Self.deepDivNest)
    }

    func testSanitizer_deepNest_stillRemovesScriptThroughTheLegacyPass() {
        let html = "<script>alert(1)</script><p onclick=\"x()\">hi</p>" + Self.deepDivNest
        let sanitized = HTMLSanitizerService.shared.sanitize(html)
        XCTAssertFalse(sanitized.lowercased().contains("<script"))
        XCTAssertFalse(sanitized.lowercased().contains("onclick"))
        XCTAssertTrue(sanitized.contains(Self.sentinel))
    }

    func testDisplayWrapper_deepDocument_isWrappedByStringSurgery() {
        let html = "<!DOCTYPE html><html><head></head><body>" + Self.deepDivNest + "</body></html>"
        let wrapped = HTMLDisplayWrapper().wrapHTMLForDisplay(html, isDarkMode: false)
        XCTAssertTrue(wrapped.contains("esc-mail-styles"))
        XCTAssertTrue(wrapped.contains("Content-Security-Policy"))
        XCTAssertTrue(wrapped.contains(Self.sentinel))
    }

    func testPreviewDOMQuery_deepNest_isNil() {
        XCTAssertNil(EmailPreviewDOMQuery(html: Self.deepDivNest))
    }

    /// Ingest on a thread with the stack every cooperative-pool thread has.
    /// Before the gate, releasing these documents overflowed it and killed
    /// the app during sync, with no verdict recorded for the message.
    func testIngestDerivation_deepNest_completesOnA512KBStackWithFallbackText() {
        let html = Self.deepDivNest
        let done = expectation(description: "derivation on a 512 KB thread")
        let results = LockedResults()
        let thread = Thread {
            results.preview = MessageProcessor.deriveHTMLChatPreview(from: html)
            results.text = TextProcessing.extractPlainText(from: html)
            results.quoteRemoved = EmailDOMQuoteRemover.removeQuotes(from: html)
            results.sanitized = HTMLSanitizerService.shared.sanitize(html)
            results.isRich = RichContentClassifier.hasGenuineRichContentAfterCleanup(html)
            done.fulfill()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        wait(for: [done], timeout: 120)

        XCTAssertEqual(results.preview.map { $0.contains(Self.sentinel) }, true)
        XCTAssertEqual(results.text.map { $0.contains(Self.sentinel) }, true)
        XCTAssertEqual(results.quoteRemoved, html)
        XCTAssertEqual(results.sanitized.map { $0.contains(Self.sentinel) }, true)
        XCTAssertNotNil(results.isRich)
    }

    /// `processGmailMessage` must not throw for a refusal: that would be a
    /// blocking per-message failure that freezes the cursor on every run.
    /// The body is persisted whole, and its text comes from the fallback.
    func testProcessGmailMessage_deepHTML_persistsTheBodyWithFallbackText() async throws {
        let html = Self.deepDivNest
        let message = GmailMessage(
            id: "deep-html",
            threadId: "deep-html-thread",
            labelIds: ["INBOX"],
            snippet: "deep",
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
                body: MessageBody(
                    size: html.utf8.count,
                    data: Data(html.utf8).base64EncodedString(),
                    attachmentId: nil
                ),
                parts: nil
            ),
            sizeEstimate: html.utf8.count
        )

        let result = try await MessageProcessor().processGmailMessage(message, myAliases: [])
        let processed = try XCTUnwrap(result)

        XCTAssertEqual(processed.htmlBody, html)
        XCTAssertEqual(processed.chatPreviewText.map { $0.contains(Self.sentinel) }, true)
        XCTAssertEqual(processed.cleanedSnippet.map { $0.contains(Self.sentinel) }, true)
    }

    // MARK: - Ordinary mail is admitted

    /// No golden-corpus output may change, and web replays the corpus: every
    /// HTML input in it must parse exactly as before.
    func testGoldenCorpusHTML_isAdmitted() throws {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "golden_message_corpus", withExtension: "json"))
        let corpus = try JSONDecoder().decode(AdmissionCorpus.self, from: Data(contentsOf: url))
        let inputs = corpus.htmlToBubbleTextCases.map(\.inputHTML)
            + corpus.richHTMLDetectionCases.map(\.inputHTML)
            + corpus.rawSourceHTMLRecoveryCases.map(\.input)
            + corpus.cleanedSnippetCases.compactMap(\.html)
        XCTAssertGreaterThan(inputs.count, 100)
        for html in inputs {
            XCTAssertNoThrow(try EmailDOMParseAdmission.admit(html), String(html.prefix(120)))
            XCTAssertLessThan(EmailDOMParseAdmission.tokenizedDepthEstimate(of: html), 100, String(html.prefix(120)))
        }
    }

    func testOrdinaryShapes_areAdmitted() {
        // A reply chain of 120 Gmail-quoted replies nests about 360 deep.
        var chain = "<div dir=\"ltr\">latest</div>"
        for index in 0..<120 {
            chain = "<div dir=\"ltr\">reply \(index)</div><div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">On a day, someone wrote:<br></div><blockquote class=\"gmail_quote\" style=\"margin:0 0 0 .8ex\">" + chain + "</blockquote></div>"
        }
        XCTAssertNoThrow(try EmailDOMParseAdmission.admit(chain))

        // A large old-style newsletter: thousands of tags, unclosed cells,
        // fonts and list items, conditional comments and a commented style
        // sheet. The scan over-counts what it leaves open, so this one is
        // measured rather than admitted on the bound.
        var newsletter = "<html><head><style><!-- td { color: red } --></style></head><body>"
        for row in 0..<300 {
            newsletter += "<!--[if mso]><table><tr><td><![endif]--><table><tr><td><font face=Arial>row \(row)<td>cell<tr><td><ul><li>a<li>b</ul></table><!--[if mso]></td></tr></table><![endif]--><p>para<p>next"
        }
        newsletter += "</body></html>"
        XCTAssertGreaterThan(EmailDOMParseAdmission.estimatedDepth(of: newsletter), EmailDOMParseAdmission.maximumDepth)
        XCTAssertNoThrow(try EmailDOMParseAdmission.admit(newsletter))
    }

    // MARK: - The bound is never below SwiftSoup's depth

    /// Shapes that a scan which reads tags too simply gets wrong: an end tag
    /// SwiftSoup reads as attribute value, raw text or comment must never
    /// close anything, and a tag it reads must never be skipped.
    func testTokenizedEstimate_crafted_isNeverBelowSwiftSoupDepth() {
        let cases: [String] = [
            String(repeating: "<div a=\"x></div>\">", count: 300),
            String(repeating: "<div a='x></div>'>", count: 300),
            String(repeating: "<div><style></div></style>", count: 300),
            String(repeating: "<div><title></div></title>", count: 300),
            // SwiftSoup ends a title at the next start tag when no `</title`
            // or `</TITLE` follows; mixed case does not count.
            String(repeating: "<div><title></div>x", count: 300),
            String(repeating: "<div><title></div>x", count: 300) + "</Title>",
            String(repeating: "<div><title></div>x", count: 300) + "</TITLE>",
            String(repeating: "<div><noframes></div></noframes>", count: 300),
            String(repeating: "<div><script><!--<script></script></div>--></script>", count: 300),
            String(repeating: "<div><!----!></div>-->", count: 300),
            String(repeating: "<div><!--x--></div><!-- </div> -->", count: 300),
            String(repeating: "<div><![CDATA[</div>]]>", count: 300),
            String(repeating: "<div><!DOCTYPE \"</div>\">", count: 300),
            String(repeating: "<div><? </div> ?>", count: 300),
            String(repeating: "<div></ </div>>", count: 300),
            String(repeating: "<div a=\"1\"/></div>", count: 300),
            String(repeating: "<div><style a / ></div></style>", count: 300),
            String(repeating: "<div><style a=1/></div></style>", count: 300),
            String(repeating: "<div><style / ><b>", count: 200),
            String(repeating: "<div><textarea></div><b>", count: 200),
            String(repeating: "<p><b>x</p>\n", count: 300),
            String(repeating: "<b><div></b>", count: 300),
            String(repeating: "<table><td><font>x<td>", count: 100),
            String(repeating: "<optgroup>", count: 300),
            String(repeating: "<div x\"=\"></div>\">", count: 300),
            String(repeating: "<é a=\"<div>\">", count: 300),
            String(repeating: "<DIV>", count: 300),
            String(repeating: "<d\u{0}iv></d\u{0}iv><div>", count: 300),
            // SwiftSoup's double escape matches `script` in lowercase only.
            String(repeating: "<div><script><!--<SCRIPT></script>", count: 300),
            String(repeating: "<div><script><!--<script></SCRIPT></script></div>--></script>", count: 300),
        ]
        for html in cases {
            let actual = Self.swiftSoupDocumentDepth(html)
            XCTAssertGreaterThanOrEqual(
                EmailDOMParseAdmission.tokenizedDepthEstimate(of: html),
                actual,
                String(html.prefix(60)).debugDescription
            )
            XCTAssertGreaterThanOrEqual(EmailDOMParseAdmission.estimatedDepth(of: html), actual)
        }
    }

    /// A `noscript` is raw text in the head and markup in the body, which no
    /// scan of the bytes can tell apart, so a body naming one keeps the first
    /// scan's count. Here SwiftSoup reads the head's `<noscript><script>` as
    /// text up to `</noscript>`, while the second scan takes the `script`
    /// for a script that runs to the end, and misses the divs.
    /// Revert-check: "noscript" in `ScannedTagName.namesWithModeDependentRawText`.
    func testEstimate_noscriptBody_keepsTheFirstScansCount() {
        let html = "<noscript><script></noscript>" + String(repeating: "<div>", count: 600)
        let actual = Self.swiftSoupDocumentDepth(html)
        XCTAssertGreaterThan(actual, 600)
        XCTAssertLessThan(EmailDOMParseAdmission.tokenizedDepthEstimate(of: html), actual)
        XCTAssertGreaterThanOrEqual(EmailDOMParseAdmission.estimatedDepth(of: html), actual)
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html))
    }

    /// Generated tag soup (seeded, so a failure reproduces): attribute values
    /// holding markup, every comment ending, raw text and its escapes,
    /// bogus comments, doctype and CDATA, uppercase and NUL in names, and
    /// unclosed and misnested elements. Parsed as a document and in each
    /// fragment context `EmailDOMFragmentParser` uses. On a thread with a
    /// large stack, since these trees are deep on purpose.
    func testEstimate_generatedTagSoup_isNeverBelowSwiftSoupDepth() {
        let done = expectation(description: "tag soup")
        let failures = LockedFailures()
        let thread = Thread {
            var generator = TagSoupGenerator(seed: 0x5EED_2026_1123)
            for iteration in 0..<3_000 {
                let html = generator.document(tokenCount: 40 + iteration % 260)
                let tokenized = EmailDOMParseAdmission.tokenizedDepthEstimate(of: html)
                let combined = EmailDOMParseAdmission.estimatedDepth(of: html)
                // The second scan defers to the first for these (`namesWithModeDependentRawText`).
                let lowercased = html.lowercased()
                let selectOrFrameset = ["<select", "<frameset", "<noscript"].contains { lowercased.contains($0) }

                let documentDepth = Self.swiftSoupDocumentDepth(html)
                if combined < documentDepth || (!selectOrFrameset && tokenized < documentDepth) {
                    failures.append("document \(documentDepth) > estimate \(tokenized)/\(combined): \(html.debugDescription)")
                }
                for context in ["table", "tbody", "tr", "colgroup", "body"] {
                    let fragmentDepth = Self.swiftSoupFragmentDepth(html, context: context)
                    if combined < fragmentDepth || (!selectOrFrameset && tokenized < fragmentDepth) {
                        failures.append("\(context) fragment \(fragmentDepth) > estimate \(tokenized)/\(combined): \(html.debugDescription)")
                    }
                }
                if failures.count > 5 { break }
            }
            done.fulfill()
        }
        thread.stackSize = 64 * 1024 * 1024
        thread.start()
        wait(for: [done], timeout: 600)
        XCTAssertEqual(failures.values, [])
    }

    func testEstimatedDepth_simpleShapes_areExactUpToTheFixedAllowance() {
        let fixed = EmailDOMParseAdmission.enclosingNodeCount + EmailDOMParseAdmission.leafAllowance
        XCTAssertEqual(EmailDOMParseAdmission.tokenizedDepthEstimate(of: "plain text"), fixed)
        XCTAssertEqual(EmailDOMParseAdmission.tokenizedDepthEstimate(of: "<div><div>x</div></div><div>y</div>"), fixed + 2)
        XCTAssertEqual(EmailDOMParseAdmission.tokenizedDepthEstimate(of: "<p>a<p>b<p>c"), fixed + 1)
        XCTAssertEqual(EmailDOMParseAdmission.tokenizedDepthEstimate(of: "<ul><li>a<li>b<li>c</ul>"), fixed + 2)
        XCTAssertEqual(EmailDOMParseAdmission.tokenizedDepthEstimate(of: "<table><tr><td>a<td>b<tr><td>c</table>"), fixed + 6)
        XCTAssertEqual(EmailDOMParseAdmission.tokenizedDepthEstimate(of: "<br><img src=x><hr>"), fixed)
    }

    // MARK: - Helpers

    /// Nodes on the longest path from the document, the document included,
    /// walked without recursion.
    private static func treeDepth(of root: Node, rootDepth: Int) -> Int {
        var deepest = 0
        var pending: [(Node, Int)] = [(root, rootDepth)]
        while let (node, depth) = pending.popLast() {
            deepest = max(deepest, depth)
            for child in node.getChildNodes() {
                pending.append((child, depth + 1))
            }
        }
        return deepest
    }

    private static func swiftSoupDocumentDepth(_ html: String) -> Int {
        guard let document = try? SwiftSoup.parse(html) else { return 0 }
        return treeDepth(of: document, rootDepth: 1)
    }

    /// As `EmailDOMFragmentParser` places them: under the body of a shell
    /// document (document, html, body above each node).
    private static func swiftSoupFragmentDepth(_ html: String, context: String) -> Int {
        let nodes: [Node]
        if context == "body" {
            guard let document = try? SwiftSoup.parseBodyFragment(html) else { return 0 }
            return treeDepth(of: document, rootDepth: 1)
        }
        guard let contextElement = try? Element(Tag.valueOf(context), ""),
              let parsed = try? Parser.parseFragment(html, contextElement, [UInt8]()) else {
            return 0
        }
        nodes = parsed
        return nodes.map { treeDepth(of: $0, rootDepth: 4) }.max() ?? 0
    }
}

// MARK: - Support

/// Written by one thread, read after `wait(for:)`.
private final class LockedResults: @unchecked Sendable {
    var error: EmailDOMParseRefusal?
    var preview: String?
    var text: String?
    var quoteRemoved: String?
    var sanitized: String?
    var isRich: Bool?
}

/// Written by the generator's thread, read after `wait(for:)`; the lock
/// keeps the two from overlapping.
private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var count: Int { lock.withLock { storage.count } }
    var values: [String] { lock.withLock { storage } }

    func append(_ failure: String) {
        lock.withLock { storage.append(failure) }
    }
}

private struct AdmissionCorpus: Decodable {
    struct HTMLCase: Decodable { let inputHTML: String }
    struct RawSourceCase: Decodable { let input: String }
    struct SnippetCase: Decodable { let html: String? }

    let htmlToBubbleTextCases: [HTMLCase]
    let richHTMLDetectionCases: [HTMLCase]
    let rawSourceHTMLRecoveryCases: [RawSourceCase]
    let cleanedSnippetCases: [SnippetCase]
}

/// Seeded tag soup for the bound comparison.
private struct TagSoupGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// SplitMix64.
    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    private mutating func pick(_ options: [String]) -> String {
        options[below(options.count)]
    }

    private static let names = [
        "div", "span", "p", "b", "i", "a", "font", "em", "strong", "u", "s", "small", "big", "code",
        "tt", "strike", "nobr", "table", "tbody", "thead", "tfoot", "tr", "td", "th", "caption",
        "colgroup", "col", "li", "ul", "ol", "dl", "dd", "dt", "option", "optgroup", "h1", "h2", "h3",
        "form", "button", "textarea", "xmp", "iframe", "noscript", "noembed", "template", "svg", "math",
        "title", "style", "script", "noframes", "br", "img", "hr", "input", "html", "head", "body",
        "image", "command", "menuitem", "frame", "blockquote", "pre", "center", "object", "marquee",
        "applet", "address", "foo", "x-y", "listing", "isindex", "keygen", "embed", "param", "wbr",
        "select", "frameset", "plaintext",
    ]

    private static let rareNames: Set<String> = ["select", "frameset", "plaintext"]

    private mutating func name() -> String {
        var name = pick(Self.names)
        while Self.rareNames.contains(name), below(8) != 0 {
            name = pick(Self.names)
        }
        switch below(10) {
        case 0: return name.uppercased()
        case 1: return name.prefix(1).uppercased() + name.dropFirst()
        default: return name
        }
    }

    private mutating func attributes() -> String {
        var result = ""
        for _ in 0..<below(3) {
            result += pick([
                " a=1", " a=\"x>y\"", " a='x>y'", " a=\"</div>\"", " a='<p>'", " a=x\"y", " a\"b=1",
                " a<b", " =x", " a = \"q\"", " b", " a/", " a=\"<style>\"", " a='</style>'",
                " a=\"--></div>\"", " c=x>y",
            ])
        }
        return result
    }

    private mutating func tagEnd() -> String {
        pick([">", ">", ">", ">", "/>", " / >", " />", "/ >"])
    }

    private mutating func token() -> String {
        switch below(20) {
        case 0..<8:
            return "<" + name() + attributes() + tagEnd()
        case 8..<12:
            return "</" + name() + (below(6) == 0 ? attributes() : "") + ">"
        case 12..<15:
            return pick(["x", " ", "\n", "<", ">", "&amp;", "é", "<é", "a<b", "\u{0}", "--", "-->", "\"", "'", "</", "<3"])
        case 15:
            return pick([
                "<!---->", "<!-->", "<!--->", "<!-- x -->", "<!----!>", "<!--x--!>", "<!-- <div> -->",
                "<!--", "--!>", "<!---x-->", "<!--x---->", "<!-- </div> -->", "<!--[if mso]><table><tr><td><![endif]-->",
            ])
        case 16:
            return pick([
                "<!x>", "<?x>", "</ x>", "</>", "<!DOCTYPE html>", "<!doctype \"a>b\">", "<![CDATA[<div>]]>",
                "<![CDATA[x", "<!DOCTYPE \"</div>\">", "</3>",
            ])
        default:
            return pick([
                "</div>", "<div>", "<!--", "<script>", "</script>", "</style >", "</STYLE>", "</stylex>",
                "-->", "</title>", "</noframes>", "<!--<script>", "</script >", "<style>", "<title>",
                "<!--<SCRIPT>", "</SCRIPT>", "</TITLE>", "</Title>", "<script >", "<noscript>", "</NOSCRIPT>",
            ])
        }
    }

    mutating func document(tokenCount: Int) -> String {
        var html = ""
        for _ in 0..<tokenCount {
            html += token()
        }
        return html
    }
}
