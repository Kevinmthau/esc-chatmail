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

    /// A formatting element an end tag passes over stays counted, as the
    /// tree builder may rebuild it, so `<div><b>x</div>` over and over
    /// passes the limit for a tree it keeps shallow; the measured parse
    /// admits it. Its 800 kept `b`s are one name and attributes, of which
    /// the active formatting list keeps three, so their rebuilding costs
    /// little. Revert-check: `TokenizingScanner.sameFormattingKept` (counting
    /// every kept `b` refuses this as too costly).
    func testParseDocument_overCountedShallowBody_isAdmittedByTheMeasuredParse() throws {
        let html = String(repeating: "<div><b>x</div>", count: 800)
        XCTAssertGreaterThan(EmailDOMParseAdmission.estimatedDepth(of: html), EmailDOMParseAdmission.maximumDepth)

        let document = try EmailDOMParseAdmission.parseDocument(html)
        XCTAssertLessThan(EmailDOMParseAdmission.measuredDepth(of: [document], rootDepth: 1), 20)
        XCTAssertEqual(try document.select("div").count, 800)
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

    /// What the second scan closes when an end tag skips an element left
    /// open (`<ul><li>a</ul>`, `<td><font>x</td>`): valid HTML of this kind
    /// is common and must not pile up until the body is refused.
    /// Revert-check: `TokenizingScanner.crossingClose`.
    func testTokenizedEstimate_endTagsOverLeftOpenElements_stayShallow() {
        let shapes = [
            "<table>" + String(repeating: "<tr><td><font>x</td></tr>", count: 1_400) + "</table>",
            String(repeating: "<table><tr><td>x</table>", count: 1_400),
            String(repeating: "<div><p>text</div>", count: 4_200),
            String(repeating: "<ul><li>a<li>b</ul>", count: 2_000),
        ]
        for html in shapes {
            XCTAssertLessThan(EmailDOMParseAdmission.tokenizedDepthEstimate(of: html), 20, String(html.prefix(40)))
            XCTAssertNoThrow(try EmailDOMParseAdmission.parseDocument(html), String(html.prefix(40)))
        }
    }

    /// An admitted body close to the limit, through ingest's DOM work on a
    /// 512 KB thread: the margin `maximumDepth` leaves for the walkers.
    func testIngestDerivation_bodyNearTheLimit_completesOnA512KBStack() {
        let html = String(repeating: "<div>", count: EmailDOMParseAdmission.maximumDepth - 12) + Self.sentinel
        XCTAssertLessThanOrEqual(EmailDOMParseAdmission.estimatedDepth(of: html), EmailDOMParseAdmission.maximumDepth)
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
        XCTAssertEqual(results.text.map { $0.contains(Self.sentinel) }, true)
        XCTAssertEqual(results.preview.map { $0.contains(Self.sentinel) }, true)
        XCTAssertNotNil(results.isRich)
    }

    // MARK: - Cost

    /// Most tags make SwiftSoup search the open elements, so a body of
    /// moderate depth and many tags costs depth × tags (`<span>` × 8,000
    /// then 200,000 `</x>` took 83 s in Release). Past `maximumTreeWork` it
    /// is refused unparsed. Revert-check: `ParseCost.excessWork`'s tree-work
    /// refusal (the body is then measured and admitted, seconds later).
    func testParseDocument_deepAndManyTags_isRefusedAsTooCostly() {
        let html = String(repeating: "<span>", count: 3_000) + String(repeating: "</x>", count: 20_000)
        let cost = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
        XCTAssertLessThanOrEqual(cost.depth, EmailDOMParseAdmission.maximumBoundForMeasuredParse)
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html)) { error in
            XCTAssertEqual(
                error as? EmailDOMParseRefusal,
                .tooCostlyToParse(work: cost.treeWork, limit: EmailDOMParseAdmission.maximumTreeWork)
            )
        }
    }

    /// Inside a `title` SwiftSoup searches the rest of the input for its end
    /// tag at every `<` and letter, so a long title of tags parses in
    /// quadratic time though it is one level deep.
    /// Revert-check: `TitleSearchCost.bytesRead` (the body is then admitted
    /// on its depth and parsed).
    func testParseDocument_titleFullOfTags_isRefusedAsTooCostly() {
        let html = "<title>" + String(repeating: "<a ", count: 40_000) + "</title><p>body</p>"
        let cost = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
        XCTAssertLessThanOrEqual(cost.depth, EmailDOMParseAdmission.maximumDepth)
        XCTAssertGreaterThan(cost.titleSearchBytes, EmailDOMParseAdmission.maximumTitleSearchBytes)
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html)) { error in
            XCTAssertEqual(
                error as? EmailDOMParseRefusal,
                .tooCostlyToParse(work: cost.titleSearchBytes, limit: EmailDOMParseAdmission.maximumTitleSearchBytes)
            )
        }
    }

    /// The title search is charged from the bytes, so a title of void tags,
    /// which the first scan does not count, is caught too (`<title>` then
    /// 640 KB of `<br ` took 31 s).
    /// Revert-check: `TitleSearchCost.bytesRead` in `ParseCost`.
    func testParseDocument_titleFullOfVoidTags_isRefusedAsTooCostly() {
        let html = "<title>" + String(repeating: "<br ", count: 40_000) + "</title><p>x</p>"
        let cost = EmailDOMParseAdmission.estimatedCost(of: html)
        XCTAssertLessThanOrEqual(cost.depth, EmailDOMParseAdmission.maximumDepth)
        XCTAssertGreaterThan(cost.titleSearchBytes, EmailDOMParseAdmission.maximumTitleSearchBytes)
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html)) { error in
            XCTAssertEqual(
                error as? EmailDOMParseRefusal,
                .tooCostlyToParse(work: cost.titleSearchBytes, limit: EmailDOMParseAdmission.maximumTitleSearchBytes)
            )
        }
    }

    /// Each formatting start tag is compared, attribute by attribute, with
    /// the active formatting elements (6,000 `<b>`s of 100 attributes took
    /// 50 s). Revert-check: `formattingCompareWork` in `ParseCost.excessWork`.
    func testParseDocument_manyAttributeHeavyFormattingTags_isRefusedAsTooCostly() {
        let attributes = (0..<100).map { " a\($0)=1" }.joined()
        let html = String(repeating: "<b\(attributes)>", count: 1_500)
        let cost = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
        XCTAssertLessThanOrEqual(cost.treeWork, EmailDOMParseAdmission.maximumTreeWork)
        XCTAssertGreaterThan(cost.formattingCompareWork, EmailDOMParseAdmission.maximumFormattingCompareWork)
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html)) { error in
            XCTAssertEqual(
                error as? EmailDOMParseRefusal,
                .tooCostlyToParse(work: cost.formattingCompareWork, limit: EmailDOMParseAdmission.maximumFormattingCompareWork)
            )
        }
    }

    /// A formatting element the tree builder closed but keeps is rebuilt
    /// before every later run of text and start tag, and each rebuild
    /// copies its attributes, quadratically (a `b` of 300 attributes left
    /// open in a `p`, rebuilt 2,000 times, took 2.7 s; of 1,000, 30 s).
    /// Revert-check: `rebuildCostAcrossTokens` in `EmailDOMParseAdmission.estimate`.
    func testParseDocument_attributeHeavyFormattingRebuiltOften_isRefusedAsTooCostly() {
        let attributes = (0..<300).map { " a\($0)=1" }.joined()
        let html = "<p><b\(attributes)>" + String(repeating: "x</p><p>", count: 2_000)
        let cost = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
        XCTAssertLessThanOrEqual(cost.depth, EmailDOMParseAdmission.maximumDepth)
        XCTAssertLessThanOrEqual(cost.formattingCompareWork, EmailDOMParseAdmission.maximumFormattingCompareWork)
        XCTAssertGreaterThan(cost.treeWork, EmailDOMParseAdmission.maximumTreeWork)
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html)) { error in
            XCTAssertEqual(
                error as? EmailDOMParseRefusal,
                .tooCostlyToParse(work: cost.treeWork, limit: EmailDOMParseAdmission.maximumTreeWork)
            )
        }
    }

    /// Each rebuild first searches the open elements for each kept element,
    /// so many kept elements under a deep stack cost their count × depth at
    /// every token (1,000 `b`s left open below 1,000 `div`s, rebuilt 500
    /// times, took 12 s for 18 KB).
    /// Revert-check: `rebuildCandidatesAcrossTokens` in `EmailDOMParseAdmission.estimate`.
    func testParseDocument_manyKeptFormattingElementsUnderADeepStack_isRefusedAsTooCostly() {
        let html = String(repeating: "<div>", count: 1_000) + "<p>"
            + (0..<1_000).map { "<b x=\($0)>" }.joined() + String(repeating: "x</p><p>", count: 500)
        let cost = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
        XCTAssertLessThanOrEqual(cost.depth, EmailDOMParseAdmission.maximumBoundForMeasuredParse)
        XCTAssertGreaterThan(cost.treeWork, EmailDOMParseAdmission.maximumTreeWork)
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html))
    }

    /// Every run of text searches the open elements too, and `<?>` or a
    /// comment splits text without a tag (`<b>`, 6,000 `<div>`s and 400,000
    /// `x<?>` took 55 s; 500 `<div>`s, 5 s on the caller's thread).
    /// Revert-check: `StartTagCount.tokenCount` counting every `<` (counting
    /// only `<` and a letter admits this).
    func testParseDocument_textSplitWithoutTags_isChargedPerRun() {
        let html = "<b>" + String(repeating: "<div>", count: 500) + String(repeating: "x<?>", count: 400_000)
        let cost = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
        XCTAssertLessThanOrEqual(cost.depth, EmailDOMParseAdmission.maximumDepth)
        XCTAssertGreaterThan(cost.treeWork, EmailDOMParseAdmission.maximumTreeWork)
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html))
    }

    /// A formatting end tag over a special element runs the adoption agency,
    /// which moves that block's children one at a time, and SwiftSoup
    /// renumbers the rest after each, so a block of n children costs n²
    /// though the tree is two levels deep (`<b><div>` and 100,000 `<br>`s
    /// then `</b>` took 14 s in a Release build, a megabyte 153 s; these,
    /// with 40,000, about 2 s each). An `<a>` while one is held runs the
    /// agency too, and comments are children as `<br>`s are.
    /// Revert-check: `TokenizingScanner.chargeAdoptionAgency` (returning at
    /// once, all three are admitted and parsed).
    func testParseDocument_formattingEndTagOverAWideBlock_isRefusedAsTooCostly() {
        let shapes = [
            "<b><div>" + String(repeating: "<br>", count: 40_000) + "</b>",
            "<a><div>" + String(repeating: "<br>", count: 40_000) + "<a>",
            "<b><div>" + String(repeating: "<!---->", count: 40_000) + "</b>",
        ]
        for html in shapes {
            let cost = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
            XCTAssertLessThanOrEqual(cost.depth, EmailDOMParseAdmission.maximumDepth)
            XCTAssertLessThanOrEqual(cost.treeWork, EmailDOMParseAdmission.maximumTreeWork)
            XCTAssertGreaterThan(cost.childMoveWork, EmailDOMParseAdmission.maximumChildMoveWork)
            XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html)) { error in
                XCTAssertEqual(
                    error as? EmailDOMParseRefusal,
                    .tooCostlyToParse(work: cost.childMoveWork, limit: EmailDOMParseAdmission.maximumChildMoveWork)
                )
            }
        }
    }

    /// The children are counted on the element the scan holds innermost,
    /// so where the tree builder gave them to an element below it, they
    /// must reach that one. Each shape gives a block 1,001 children
    /// (measured against SwiftSoup), then moves them all.
    /// - A `div` closed at once (`<div/>`) makes the next `</div>` close the
    ///   one around it, so the `<br>`s the scan counts on that one go to the
    ///   `li`. Revert-check: `doubtClosing(of:)` in `closeElement`.
    /// - Text and tags in a table are foster parented before it, in the
    ///   `div`. Revert-check: the `fosterableCounts` branch of
    ///   `releaseChildren`.
    /// - SwiftSoup ignores a second `<form>` while its form pointer is set,
    ///   so the `<br>`s go to the first. Revert-check:
    ///   `ScannedTagName.mayNotStayOpen`.
    /// - SwiftSoup 2.13.5 inserts an `xmp` as any other element, closing no
    ///   `p`. Revert-check: `xmp` back in `ScannedTagName.closesParagraph`.
    /// - In a table part's fragment SwiftSoup inserts a `form` without
    ///   closing the `p`. Revert-check: the `name != N.form` in
    ///   `closeImpliedElements`.
    func testChildMoveWork_childrenGivenToALowerElement_reachIt() {
        let children = 1_001
        let brs = String(repeating: "<br>", count: 1_000)
        let shapes: [(html: String, isTableContextFragment: Bool)] = [
            ("<b><li><div><div/></div>" + brs + "</div></b>", false),
            ("<b><div><table>" + String(repeating: "x<br>", count: 1_000) + "</table></b>", false),
            ("<b><div><form><form></form>" + brs + "</form></b>", false),
            ("<b><p>" + brs + "<xmp></b>", false),
            ("<b><p>" + brs + "<form></b>", true),
        ]
        for shape in shapes {
            XCTAssertGreaterThanOrEqual(
                EmailDOMParseAdmission.estimatedCost(of: shape.html, isTableContextFragment: shape.isTableContextFragment)
                    .childMoveWork,
                children * children,
                String(shape.html.prefix(40))
            )
        }
    }

    /// Misnested formatting is common in old mail, and is charged for the
    /// children of the blocks it may move, not for everything under them: a
    /// `p` closed inside a `b` on every line moves one child (2,000 in all,
    /// measured against SwiftSoup), and is charged about one percent of the
    /// limit, each `</b>` counting up to eight passes over the `b`s held. A
    /// wrapper closed out of order moves its 4,000 children (two a line,
    /// 16,000,000), not the tables' content.
    func testChildMoveWork_ordinaryMisnesting_isChargedOnlyTheMovedChildren() {
        let lines = String(repeating: "<b><p>some text</b> more</p>\n", count: 2_000)
        XCTAssertLessThan(
            EmailDOMParseAdmission.estimatedCost(of: lines).childMoveWork,
            EmailDOMParseAdmission.maximumChildMoveWork / 20
        )

        let wrapper = "<font face=Arial><div>"
            + String(repeating: "<table><tr><td>cell<br>text</td></tr></table>\n", count: 2_000)
            + "</font></div>"
        let cost = EmailDOMParseAdmission.estimatedCost(of: wrapper)
        XCTAssertGreaterThanOrEqual(cost.childMoveWork, 16_000_000)
        XCTAssertLessThanOrEqual(cost.childMoveWork, 4 * 16_000_000)
        XCTAssertNoThrow(try EmailDOMParseAdmission.admit(wrapper))
    }

    /// Where the second scan cannot follow the markup (here after a
    /// `select`), a formatting tag's attributes are read from every place
    /// one could start, a `>` in a quoted value included, and every earlier
    /// formatting tag counts as rebuilt at every token with the most of them.
    /// Revert-check: `FormattingAttributeBound.maximumAttributeCount` (with
    /// it returning 0 this is admitted, and its parse takes 2.7 s in Release).
    func testParseDocument_attributeHeavyFormattingAfterASelect_isRefusedAsTooCostly() {
        let attributes = (0..<300).map { " a\($0)=1" }.joined()
        let html = "<select></select><p><b a=\">\"\(attributes)>" + String(repeating: "x</p><p>", count: 2_000)
        XCTAssertFalse(EmailDOMParseAdmission.followedTokenizedDepthEstimate(of: html).followed)
        let cost = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
        XCTAssertGreaterThan(cost.treeWork, EmailDOMParseAdmission.maximumTreeWork)
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html))
    }

    /// Reading every place a formatting tag could start must stay linear
    /// however the reads overlap: in `<b/a=y<b/a=y…` every one runs to the
    /// end. On its own thread, so a regression fails by timeout.
    /// HONEST SCOPE: the reads are merged by state by construction
    /// (`FormattingAttributeBound`), so no single line reverts to the
    /// quadratic reading; this pins that the estimate stays fast.
    func testEstimatedCost_overlappingFormattingTagReadsAfterASelect_isLinear() {
        let html = "<select><b/a=" + String(repeating: "y<b/a=", count: 200_000)
        let done = expectation(description: "estimate")
        let thread = Thread {
            _ = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
            done.fulfill()
        }
        thread.start()
        wait(for: [done], timeout: 20)
    }

    /// An ordinary title costs next to nothing, in a body long enough that
    /// the second scan reads it.
    func testEstimatedCost_ordinaryTitle_isSmall() {
        let html = "<html><head><title>Your <b>order</b> shipped</title></head><body>"
            + String(repeating: "<div>hi</div>", count: 600) + "</body></html>"
        let cost = EmailDOMParseAdmission.estimatedCost(of: html)
        XCTAssertGreaterThan(cost.titleSearchBytes, 0)
        XCTAssertLessThan(cost.titleSearchBytes, 100)
        XCTAssertNil(cost.excessWork)
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

    /// A refused body is shown as its escaped text, never through the legacy
    /// regex pass: that pass removes a tag once, so a tag split around itself
    /// re-forms (`<me<meta>ta http-equiv="refresh" …>` became a working meta
    /// refresh), and any sender can cause a refusal.
    /// Revert-check: the `catch is EmailDOMParseRefusal` branches in
    /// `HTMLSanitizerService` (without them the meta refresh survives).
    func testSanitizer_refusedBody_keepsNoneOfTheSendersMarkup() {
        let attack = "<me<meta>ta http-equiv=\"refresh\" content=\"0;url=https://attacker.example/\">"
            + "<scr<script>ipt>alert(1)</scr</script>ipt><p onclick=\"x()\">hi</p>"
        for body in [attack + Self.deepDivNest, attack + String(repeating: "<div>", count: 9_000)] {
            for sanitized in [
                HTMLSanitizerService.shared.sanitize(body),
                HTMLSanitizerService.shared.removeOriginalReaderActiveMarkupAndEventHandlers(body),
            ] {
                let markup = sanitized.replacingOccurrences(of: "<br>", with: "")
                XCTAssertFalse(markup.contains("<"), String(markup.prefix(200)))
                XCTAssertTrue(sanitized.contains("hi"))
            }
        }
        XCTAssertTrue(HTMLSanitizerService.shared.sanitize(Self.deepDivNest).contains(Self.sentinel))
    }

    /// Other parse failures keep the legacy pass, as before.
    func testSanitizer_otherDOMFailure_stillUsesTheLegacyPass() {
        struct Failure: Error {}
        let service = HTMLSanitizerService(dangerousMarkupSanitizer: { _ in throw Failure() })
        let sanitized = service.sanitize("<p>hi</p><script>alert(1)</script>")
        XCTAssertTrue(sanitized.contains("<p>hi</p>"))
        XCTAssertFalse(sanitized.lowercased().contains("<script"))
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
        // sheet.
        var newsletter = "<html><head><style><!-- td { color: red } --></style></head><body>"
        for row in 0..<300 {
            newsletter += "<!--[if mso]><table><tr><td><![endif]--><table><tr><td><font face=Arial>row \(row)<td>cell<tr><td><ul><li>a<li>b</ul></table><!--[if mso]></td></tr></table><![endif]--><p>para<p>next"
        }
        newsletter += "</body></html>"
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
            // SwiftSoup takes the byte after `</style` or `</script` as text
            // when it does not end the tag, so a `<` there starts nothing.
            "<style></style</style x><plaintext></style>" + String(repeating: "<span>", count: 300),
            "<script></script</script x><plaintext></script>" + String(repeating: "<span>", count: 300),
            "<script><!--</script</script x><plaintext></script>" + String(repeating: "<span>", count: 300),
            "<noframes></noframes\u{e9}</noframes x><plaintext></noframes>" + String(repeating: "<span>", count: 300),
            String(repeating: "<div><title></title<b></title>", count: 300),
            // Outside a table SwiftSoup ignores a table part, and it closes a
            // self-closing element at once: neither may close what is above.
            String(repeating: "<tr><span><span><span></tr>", count: 300),
            String(repeating: "<div><table/><span><span></table>", count: 300),
            String(repeating: "<caption><b><b></caption>", count: 300),
            // SwiftSoup's head takes a `command`, so the `noscript` after it
            // is the head's, its `<plaintext>` text, and the divs markup.
            // Revert-check: `command` in `ScannedTagName.headStartTags`.
            "<command><noscript><plaintext></noscript>" + String(repeating: "<div>", count: 600),
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

    /// A formatting element popped with a marker stays in SwiftSoup's
    /// active formatting list wherever the marker's own clear does not reach
    /// it, and is rebuilt at the next text under the divs that follow: 200
    /// of each built 404 levels where the second scan said about 210.
    /// - A `caption` closed by a table part is still held by the scan, and
    ///   the fonts after it were taken as cleared with it at `</table>`.
    ///   Revert-check: `OpenElement.clearedWithMarkerAt` in `crossingClose`
    ///   (releasing every formatting element above a marker popped with it).
    /// - A `</td>` with no `td` in scope leaves the `th` for the row's mode,
    ///   whose `</table>` pops it without the clear. Revert-check: the
    ///   `isCertainlyInTableScope` line in `closeElement`.
    /// - An `object` popped by `</table>` leaves its marker in the list, and
    ///   the cell's clear stops there. Revert-check:
    ///   `ScannedTagName.markersLeftInTheList`.
    func testEstimate_formattingPoppedWithAMarkerItsClearMisses_staysCounted() {
        let fonts = (0..<200).map { "<font class=f\($0)>" }.joined()
        let divs = String(repeating: "<div>", count: 200) + "x"
        let shapes = [
            "<table><caption><tbody>" + fonts + "</table>" + divs,
            "<table><tr><th>" + fonts + "</td></table>" + divs,
            "<table><tr><td>" + fonts + "<object></table>" + divs,
        ]
        for html in shapes {
            let actual = Self.swiftSoupDocumentDepth(html)
            XCTAssertGreaterThan(actual, 400)
            XCTAssertGreaterThanOrEqual(EmailDOMParseAdmission.tokenizedDepthEstimate(of: html), actual, String(html.prefix(20)))
            XCTAssertGreaterThanOrEqual(EmailDOMParseAdmission.estimatedDepth(of: html), actual)
        }
    }

    /// In the head SwiftSoup reads every tag inside a `noscript` as text,
    /// so the head's `<noscript><script>` is text up to `</noscript>`, and
    /// the divs after it are markup. The second scan follows that where the
    /// tree builder is certainly still in the head; taking the `script` for
    /// a script that runs to the end, it missed the divs.
    /// Revert-check: `TokenizingScanner.headNoscriptTag`.
    func testEstimate_noscriptInTheHead_isFollowed() {
        let html = "<noscript><script></noscript>" + String(repeating: "<div>", count: 600)
        let actual = Self.swiftSoupDocumentDepth(html)
        XCTAssertGreaterThan(actual, 600)
        let followed = EmailDOMParseAdmission.followedTokenizedDepthEstimate(of: html)
        XCTAssertTrue(followed.followed)
        XCTAssertGreaterThanOrEqual(followed.depth, actual)
        XCTAssertGreaterThanOrEqual(EmailDOMParseAdmission.estimatedDepth(of: html), actual)
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html))
    }

    /// Where the scan cannot be certain the tree builder is still in the
    /// head (here a character reference, which SwiftSoup reads as the
    /// whitespace it is), a `noscript` keeps the first scan's count, since
    /// in the body its content is markup.
    /// Revert-check: the text rule for `certainlyInHead` in
    /// `TokenizingScanner.run`.
    func testEstimate_noscriptWhereTheHeadIsUncertain_keepsTheFirstScansCount() {
        let html = "&#32;<noscript><script></noscript>" + String(repeating: "<div>", count: 600)
        let actual = Self.swiftSoupDocumentDepth(html)
        XCTAssertGreaterThan(actual, 600)
        XCTAssertFalse(EmailDOMParseAdmission.followedTokenizedDepthEstimate(of: html).followed)
        XCTAssertGreaterThanOrEqual(EmailDOMParseAdmission.estimatedDepth(of: html), actual)
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html))
    }

    /// A newsletter whose head holds a `noscript` (a tracking pixel's
    /// stylesheet) is read precisely and admitted. Counted as if every
    /// earlier formatting tag were held at every token, this one was
    /// refused as too costly and shown as escaped text.
    /// Revert-check: the `certainlyInHead` branch of the `noscript` rule in
    /// `TokenizingScanner.openElement` (the body then falls back to the
    /// pessimistic count and is refused).
    func testEstimate_newsletterWithNoscriptInTheHead_isAdmitted() {
        let rows = String(
            repeating: "<p><a href=\"https://example.com/a\" style=\"color:red\" target=_blank>Item</a> text</p>\n",
            count: 1_500
        )
        let html = "<html><head><meta charset=utf-8><noscript><link rel=stylesheet href=x.css></noscript></head><body>"
            + rows + "</body></html>"
        XCTAssertNil(EmailDOMParseAdmission.estimatedCost(of: html).excessWork)
        XCTAssertNoThrow(try EmailDOMParseAdmission.parseDocument(html))
    }

    /// Only a `select` or `frameset` the tokenizer reads, or a `noscript` in
    /// the head, makes the first scan's count decide; a mention in a comment
    /// or a `noscript` tracking pixel in the body does not, so a large
    /// newsletter carrying one is still read precisely and admitted.
    /// Revert-check: `TokenizingScanner.readModeDependentTag` (deciding on
    /// any mention of the names refuses these).
    func testEstimate_modeDependentNamesOutsideTheirModes_keepThePreciseBound() {
        var rows = ""
        for row in 0..<1_500 {
            rows += "<tr><td><a href=\"https://example.com/\(row)\"><font face=Arial>row \(row)</font></a> <b>x</b></td></tr>"
        }
        let newsletter = "<html><head><title>News</title></head><body><table>" + rows + "</table>"
        for html in [
            newsletter + "<!-- <select> <noscript> --></body></html>",
            newsletter + "<noscript><img src=\"https://t.example.com/p.gif\"></noscript></body></html>",
            newsletter + "<input value=\"<frameset>\"></body></html>",
        ] {
            XCTAssertLessThan(EmailDOMParseAdmission.estimatedDepth(of: html), 30, String(html.suffix(80)))
            XCTAssertNoThrow(try EmailDOMParseAdmission.parseDocument(html), String(html.suffix(80)))
        }
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
            // 1,000 documents keep this near 20 s in CI; the same generator
            // ran over a million documents off the suite before merging.
            for iteration in 0..<1_000 {
                let html = generator.document(tokenCount: 40 + iteration % 260)
                // The second scan's depth is a bound on its own only where it
                // followed the markup to the end (`readModeDependentTag`).
                let tokenized = EmailDOMParseAdmission.followedTokenizedDepthEstimate(of: html)
                let combined = EmailDOMParseAdmission.estimatedDepth(of: html)

                let documentDepth = Self.swiftSoupDocumentDepth(html)
                if combined < documentDepth || (tokenized.followed && tokenized.depth < documentDepth) {
                    failures.append("document \(documentDepth) > estimate \(tokenized.depth)/\(combined): \(html.debugDescription)")
                }
                // A body fragment starts in the body, as `parseBodyFragment` estimates it.
                let bodyTokenized = EmailDOMParseAdmission.followedTokenizedDepthEstimate(of: html, readsHead: false)
                let bodyCombined = EmailDOMParseAdmission.estimatedCost(of: html, readsHead: false).depth
                let bodyDepth = Self.swiftSoupFragmentDepth(html, context: "body")
                if bodyCombined < bodyDepth || (bodyTokenized.followed && bodyTokenized.depth < bodyDepth) {
                    failures.append("body fragment \(bodyDepth) > estimate \(bodyTokenized.depth)/\(bodyCombined): \(html.debugDescription)")
                }
                // `EmailDOMFragmentParser`'s table-part contexts, estimated
                // as `EmailDOMParseAdmission.parseFragment` estimates them.
                let fragmentTokenized = EmailDOMParseAdmission.followedTokenizedDepthEstimate(of: html, isTableContextFragment: true)
                let fragmentCombined = EmailDOMParseAdmission.estimatedCost(of: html, isTableContextFragment: true).depth
                for context in ["table", "tbody", "tr", "colgroup"] {
                    let fragmentDepth = Self.swiftSoupFragmentDepth(html, context: context)
                    if fragmentCombined < fragmentDepth || (fragmentTokenized.followed && fragmentTokenized.depth < fragmentDepth) {
                        failures.append("\(context) fragment \(fragmentDepth) > estimate \(fragmentTokenized.depth)/\(fragmentCombined): \(html.debugDescription)")
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

    /// The gate runs before every parse, so it must be linear in anything a
    /// sender writes. Reading each tag name to its end made the first scan
    /// quadratic on a run of `<a` with no delimiter: about 3 s for 200 KB in
    /// a Release build, minutes per parse for a megabyte. Here 400 KB, which
    /// a linear scan reads in milliseconds and the quadratic one took far
    /// longer than the timeout. On its own thread, so a regression fails by
    /// timeout rather than hanging the suite.
    /// Revert-check: `StartTagCount.nameLengthRead`.
    func testEstimatedDepth_delimiterlessTagRun_isLinear() {
        let html = "<p>hi</p>" + String(repeating: "<a", count: 200_000)
        let done = expectation(description: "scan")
        let results = LockedResults()
        let thread = Thread {
            results.text = String(EmailDOMParseAdmission.estimatedDepth(of: html))
            done.fulfill()
        }
        thread.start()
        wait(for: [done], timeout: 20)
        XCTAssertNotNil(results.text)
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
                "</style<", "</script<", "</title<", "</noframes\"", "</STYLE<", "</script\u{e9}", "<plaintext>",
            ])
        }
    }

    mutating func document(tokenCount: Int) -> String {
        // A quarter open in the head, so a `noscript` is read as the head's.
        var html = below(4) == 0
            ? pick(["<head>", "<html><head><meta charset=utf-8>", " <!--x--><noscript>", "<noscript>", "<title>t</title><NOSCRIPT>"])
            : ""
        for _ in 0..<tokenCount {
            html += token()
        }
        return html
    }
}
