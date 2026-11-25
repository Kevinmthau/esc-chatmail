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
    /// - Tags in a table are foster parented before it, in the `div` (text
    ///   is not: SwiftSoup appends it to the table part). Revert-check: the
    ///   `fosterableCounts` branch of `releaseChildren`.
    /// - SwiftSoup ignores a second `<form>` while its form pointer is set,
    ///   so the `<br>`s go to the first. Revert-check:
    ///   `ScannedTagName.mayNotStayOpen`.
    /// - SwiftSoup 2.13.5 inserts an `xmp` as any other element, closing no
    ///   `p`. Revert-check: `xmp` back in `ScannedTagName.closesParagraph`.
    /// - In a table part's fragment SwiftSoup inserts a `form` without
    ///   closing the `p`. Revert-check: the `name != N.form` in
    ///   `closeImpliedElements`.
    /// - SwiftSoup drops an `rp` or `rt` with no `ruby` in scope, and inserts
    ///   a `command` empty, so the `<br>`s go to the `div` and their end
    ///   tags close nothing. Revert-check: `rp` and `rt` in
    ///   `ScannedTagName.mayNotStayOpen`, `command` in
    ///   `ScannedTagName.voidNames` (each shape gave 1,000 children, or
    ///   1,001, and was charged 9).
    /// - SwiftSoup pushes no marker for a `template` and does not stop its
    ///   search there, so the `b` below it is found. Revert-check:
    ///   `ScannedTagName.agencyMarkers` without `template`.
    /// - SwiftSoup reads `</br>` as `<br>`, which rebuilds the `b` kept at
    ///   `</p>`; the `div` after it is that copy's furthest block.
    ///   Revert-check: `noteTokenThatMayRebuild` for `</br>` in
    ///   `closeElement`.
    /// - In a table part's fragment a `</table>` closes the `caption`, and
    ///   the `object` in it, with no `table` held: the `object` was taken
    ///   for a marker still open, and the `<a class=k>` charged nothing
    ///   (generated tag soup, which SwiftSoup has move 2 children twice).
    ///   Revert-check: `ScannedTagName.tableEndTargets`.
    /// - The `<a>` inside the cell finds no `a` past the cell's marker and
    ///   takes nothing out of the list, so the `a` kept at `</p>` is rebuilt
    ///   above the `div` and found by `</a>`. Revert-check: the marker guard
    ///   in `consumeAKeptOne`.
    /// - An `rp` with a `ruby` in scope pops everything above the `ruby`,
    ///   the `b` too, which text in the table then rebuilds. Revert-check:
    ///   the `ruby` rule in `ScannedTagName.closingRules(forStartTag:)`.
    /// - SwiftSoup closes a heading for a heading only if the current node
    ///   was one before it closed the `p`, so the second `h1` nests in the
    ///   first, which keeps its `<br>`s. Revert-check: `headingWasInnermost`
    ///   in `closeImpliedElements`. Nor when a copy rebuilt since the
    ///   heading was pushed is the current node: text after `</p>` rebuilds
    ///   the `b` inside the first `h1`. Revert-check: `lastRebuildAt` in
    ///   `closeImpliedElements`.
    /// - A copy of a kept `b` that Noah's ark took out of the list stays on
    ///   the stack, and a later `</b>` closes it with the `span` above it
    ///   (`anyOtherEndTag`), whose `<br>`s go to the `div`. Revert-check:
    ///   `lingeringCopySinceByName` in `closeElement`.
    func testChildMoveWork_childrenGivenToALowerElement_reachIt() {
        let children = 1_000
        let brs = String(repeating: "<br>", count: 1_000)
        let shapes: [(html: String, isTableContextFragment: Bool)] = [
            ("<b><li><div><div/></div>" + brs + "</div></b>", false),
            ("<b><div><table>" + String(repeating: "x<br>", count: 1_000) + "</table></b>", false),
            ("<b><div><form><form></form>" + brs + "</form></b>", false),
            ("<b><p>" + brs + "<xmp></b>", false),
            ("<b><p>" + brs + "<form></b>", true),
            ("<b><div><rp>" + brs + "</rp></b>", false),
            ("<b><div><rt>" + brs + "</rt></b>", false),
            ("<b><div><command>" + brs + "</command></b>", false),
            ("<b><div>" + brs + "<template></b>", false),
            ("<p><b>x</p></br><div>" + brs + "</b>", false),
            ("<p><a>t</p><table><td><table></table><a></a></table>z<div>" + brs + "</a>", false),
            ("<div><ruby><b><rp></rp><table>x<p>" + brs + "</b>", false),
            ("<a><h1>" + brs + "<p><h1></a>", false),
            ("<font><h1>" + brs + "<p><b>t</p> <h1></font>", false),
            ("<i><div><p><b>t</p>x<b><b><b></b></b></b><p></b></p><span></b>" + brs + "</span></i>", false),
            ("<i><div><p><b>t</p>x" + String(repeating: "<b class=x>", count: 4) + String(repeating: "</b>", count: 4)
                + "<p></b></p><span></b>" + brs + "</span></i>", false),
        ]
        for shape in shapes {
            XCTAssertGreaterThanOrEqual(
                EmailDOMParseAdmission.estimatedCost(of: shape.html, isTableContextFragment: shape.isTableContextFragment)
                    .childMoveWork,
                children * children,
                String(shape.html.prefix(40))
            )
        }
        let captionClosedByTableEnd = "<address><b><center><i><blockquote></isindex><font><caption><b class=k/></s>"
            + "</button><s></x-y><a></nobr><section><object></u><p><font></ol></span><frame></div></s><font></table>"
            + "<address><isindex></iframe></s></textarea><option><ol></u></th><a class=k></li><ol></br><font>"
            + String(repeating: "<img>", count: 60) + "</font></em></nobr>"
        XCTAssertGreaterThanOrEqual(
            EmailDOMParseAdmission.estimatedCost(of: captionClosedByTableEnd, isTableContextFragment: true).childMoveWork,
            4
        )
    }

    /// While a table fosters, every formatting element the builder rebuilds
    /// goes to the table's parent beside the others (`insertNode`), not
    /// inside the one before, ten at each `x`: the `div` holds 4,002
    /// children (measured against SwiftSoup), at 400 rows 16 million in
    /// all, at 4,000 rows 24 s.
    /// Revert-check: `rebuildsFormatting` in `countChildren` (charged
    /// 160,000). With a `<div/>` after the `<table>` the scan's innermost
    /// element is one the builder closed at once, while its current node is
    /// still the table (16,024,009 measured). Revert-check: the
    /// `fosteringPartsHeld` term in `countChildren`.
    func testChildMoveWork_formattingRebuiltWhileFostering_countsEachCopy() {
        let formatting = (0..<10).map { "<b class=c\($0)>" }.joined()
        let html = "<i><div><p>" + formatting + "</p><table>" + String(repeating: "x<tr>", count: 400) + "</table></i>"
        XCTAssertGreaterThanOrEqual(EmailDOMParseAdmission.estimatedCost(of: html).childMoveWork, 16_016_004)
        let underAClosedDiv = "<i><div><p>" + formatting + "</p><table><div/>" + String(repeating: "x<col>", count: 400) + "</table></i>"
        XCTAssertGreaterThanOrEqual(EmailDOMParseAdmission.estimatedCost(of: underAClosedDiv).childMoveWork, 16_024_009)
    }

    /// Stray and misnested formatting end tags are everywhere in old mail,
    /// and SwiftSoup moves nothing for any of these (measured; at most one
    /// paragraph for the `<a>` left open). Each but the last was refused
    /// here before:
    /// the agency was charged for a `font` behind a cell's marker, for an
    /// `a` it had already taken out of the list, and for kept elements no
    /// copy of which could be on the stack yet.
    /// Revert-check: `agencyCannotReach` in `chargeAdoptionAgency` and in
    /// `closeElement` (the cell shapes), `retireIfTheAgencyTakesIt` (the `<a>`
    /// left open over paragraphs), `consumeAKeptOne` (the links on every
    /// line), `firstPossibleCopyAtByName` (the list after a kept `b`, which
    /// no token rebuilds before its `</b>`), `opensTheOnlyTable` in
    /// `lowestTargetOfStartTag` (a stray `</font>` between rows), the
    /// effective kept count in `markPossiblyClosed(by:)` (`</strong>` after
    /// `</p>` on every line), the copy branch of `consumeAKeptOne` (`</b>`
    /// after text rebuilt it), and the release of a kept one's counts in
    /// `consumeAKeptOne` (4,000 lines of `<p><font face=Arial>text</p></font>`,
    /// whose held `font`s otherwise grew a line at a time, and with them the
    /// active-formatting comparisons).
    func testChildMoveWork_strayFormattingEndTags_chargeNothing() {
        func lines(_ count: Int, _ line: String) -> String { String(repeating: line, count: count) }
        let mailingTemplate = "<font face=Arial><center>"
            + (0..<1_500).map { "<table><tr><td>row \($0)" + ($0 % 50 == 0 ? "</font>" : "") + "</td></tr></table>\n" }.joined()
            + "</center></font>"
        let shapes = [
            "<div>" + lines(200, "<p><font face=Arial>text</p></font>\n"),
            lines(300, "<p><b>text</p></b>"),
            "<font face=Arial><table>" + lines(400, "<tr><td><span>text</span></font></td></tr>"),
            mailingTemplate,
            "<a href=x><table>" + lines(600, "<tr><td><a href=y>l</a></td></tr>"),
            "<a href=x><div>" + lines(600, "<p><a href=y>l</a></p>"),
            lines(300, "<p><a href=x>link</p>"),
            "<div><p><b>x</p><ul>" + lines(1_000, "<li>") + "</b>",
            "<font face=Arial><table width=600>" + lines(200, "<tr><td><font size=2>Row text</td></tr></font>\n") + "</table></font>",
            "<div><font face=Verdana><center>" + lines(1_000, "<p><strong>text<br></p></strong>\n") + "</center></font></div>",
            "<div><font face=Verdana><center>" + lines(1_000, "<p><b>x</p> tail</b>\n") + "</center></font></div>",
            "<div>" + lines(4_000, "<p><font face=Arial>text</p></font>\n"),
            "<div><font face=Verdana><center>" + lines(3_000, "<p><strong>text<br></p></strong>\n") + "</center></font></div>",
        ]
        for html in shapes {
            XCTAssertLessThan(EmailDOMParseAdmission.estimatedCost(of: html).childMoveWork, 100_000, String(html.prefix(40)))
            XCTAssertNoThrow(try EmailDOMParseAdmission.parseDocument(html), String(html.prefix(40)))
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
        XCTAssertNoThrow(try EmailDOMParseAdmission.parseDocument(wrapper))
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

    /// A tag's attributes are made into its list when something first reads
    /// one, each name compared with every name kept before it
    /// (`Attributes.ensureMaterialized`), so a tag of n distinct names costs
    /// n², all of it after the parse (one `<div>` of 16,000 names: 0.9 s in a
    /// Release build, 27 s in the app's Debug build, in the quote remover's
    /// first selector). These take about 1.5 s in a Release build. The
    /// second scan reads the first two; `<select>` makes the last two the
    /// byte bound's.
    /// Revert-check: the `dedupWork` addition in `AttributeWork.read` (all
    /// four are admitted), and `AttributeWorkBound.work` (returning an empty
    /// `AttributeWork`, the last two are).
    func testParseDocument_tagOfManyDistinctAttributeNames_isRefusedAsTooCostly() {
        let names = (0..<20_000).map { " a\($0)=1" }.joined()
        let eventNames = (0..<20_000).map { " on\($0)=1" }.joined()
        let shapes = [
            "<div" + names + ">x</div>",
            "<p><div" + eventNames + ">x</div>",
            "<div" + names + ">x</div><select>",
            "<select><option" + eventNames + ">",
        ]
        for html in shapes {
            let cost = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
            XCTAssertLessThanOrEqual(cost.depth, EmailDOMParseAdmission.maximumDepth)
            XCTAssertLessThanOrEqual(cost.treeWork, EmailDOMParseAdmission.maximumTreeWork)
            XCTAssertLessThanOrEqual(cost.childMoveWork, EmailDOMParseAdmission.maximumChildMoveWork)
            XCTAssertGreaterThan(cost.attributeDedupWork, EmailDOMParseAdmission.maximumAttributeDedupWork)
            XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html)) { error in
                XCTAssertEqual(
                    error as? EmailDOMParseRefusal,
                    .tooCostlyToParse(work: cost.attributeDedupWork, limit: EmailDOMParseAdmission.maximumAttributeDedupWork)
                )
            }
        }
    }

    /// Each name costs a comparison with every name before it in its tag, of
    /// one more than its length: the most SwiftSoup's search compares
    /// (equal lengths are compared byte by byte). A NUL is three bytes,
    /// because SwiftSoup writes U+FFFD for it. A quote, `<` or NUL after a
    /// name and whitespace goes on that name in SwiftSoup, which the scan
    /// reads as a name of its own: a finer split, never cheaper.
    /// HONEST SCOPE: SwiftSoup's comparisons cannot be counted here. A copy
    /// of SwiftSoup 2.13.5 that counts them was compared with this charge
    /// over a million attribute-heavy documents (tag soup, quotes, NUL,
    /// `<`, `/`, mode-dependent markup), off the suite, with none above it.
    /// Revert-check: the NUL width in `AttributeWork.read` (`withNul`), and
    /// the dedup's `startsAttribute` term there (`plain`).
    func testAttributeDedupWork_eachNameIsChargedForTheNamesBeforeIt() {
        func work(_ html: String) -> Int {
            EmailDOMParseAdmission.estimatedCost(of: html).attributeDedupWork
        }
        // 0 + 1·(1 + 1) + 2·(1 + 2)
        XCTAssertEqual(work("<div a b=1 cc='x'>"), 8, "plain")
        // 0 + 1·(1 + 3)
        XCTAssertEqual(work("<div a \u{0}>"), 4, "withNul")
        // 0 + 1·(1 + 2), read as two names
        XCTAssertEqual(work("<div a \"b>"), 3)
        // Each tag's names are its own; end tags are charged too.
        XCTAssertEqual(work("<p a b></p c d><p e f>"), 6)
        XCTAssertEqual(work("<div>"), 0)
        XCTAssertEqual(work("<div a=\"<b c d e\">"), 0)
    }

    /// Where the second scan cannot follow the markup, every `<` and letter
    /// is read as a tag, from each state at once: never below what the
    /// second scan charges for the same tags, and linear however the reads
    /// overlap.
    func testAttributeDedupWork_byteBound_isNeverBelowTheSecondScan() {
        let shapes = [
            "<div a b=1 cc='x'>",
            "<div a \u{0} \"b <c d>",
            "<p a b></p c d><p e f>",
            "<div title=\"<a b c\" d e>",
            "<div a/b/c/d>",
            "<a b c<d e f>",
            "<style><x a b c></style><div d e>",
        ]
        for html in shapes {
            let followed = EmailDOMParseAdmission.estimatedCost(of: html).attributeDedupWork
            let bound = EmailDOMParseAdmission.estimatedCost(of: html + "<select>").attributeDedupWork
            XCTAssertGreaterThanOrEqual(bound, followed, html.debugDescription)
        }

        // Every "<" starts a read that runs to the one ">" at the end.
        let overlapping = String(repeating: "<a b ", count: 20_000) + ">"
        let start = Date()
        _ = EmailDOMParseAdmission.estimatedCost(of: overlapping + "<select>")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// An `html` or `body` start tag gives the root element its names, and
    /// each one added rebuilds the list's key indexes over every name the
    /// root holds, so the cost grows with the square of the names all such
    /// tags gave (4,000 `<html a b c d>`s: 10 s in a Release build, in the
    /// parse; one `<html>` of 11,000 names: 5.3 s). The last is read by the
    /// byte bound (`<select>`).
    /// Revert-check: `mergesIntoRoot` in `TokenizingScanner.readTag`
    /// (passing false, the first three are admitted), and the `html`/`body`
    /// readings of `AttributeWorkBound.work` (the last is).
    func testParseDocument_manyNamesGivenToTheRoot_isRefusedAsTooCostly() {
        let tags = (0..<4_000).map { " a\($0) b\($0) c\($0) d\($0)>" }
        let names = (0..<11_000).map { " n\($0)" }.joined()
        let shapes = [
            "<html><body>x" + tags.map { "<html" + $0 }.joined(),
            "<html><body>x" + tags.map { "<BODY" + $0 }.joined(),
            "<html><body>x<html" + names + ">",
            "<html><body>x" + tags.map { "<html" + $0 }.joined() + "<select>",
        ]
        for html in shapes {
            let cost = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
            XCTAssertLessThanOrEqual(cost.treeWork, EmailDOMParseAdmission.maximumTreeWork, String(html.prefix(40)))
            XCTAssertLessThanOrEqual(cost.attributeDedupWork, EmailDOMParseAdmission.maximumAttributeDedupWork)
            XCTAssertGreaterThan(cost.rootAttributeMergeWork, EmailDOMParseAdmission.maximumRootAttributeMergeWork)
            XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html)) { error in
                XCTAssertEqual(
                    error as? EmailDOMParseRefusal,
                    .tooCostlyToParse(
                        work: cost.rootAttributeMergeWork,
                        limit: EmailDOMParseAdmission.maximumRootAttributeMergeWork
                    )
                )
            }
        }
    }

    /// Each attribute name made into an element's list after the parse, or
    /// removed from it by the sanitizer, marks the element's query indexes
    /// stale up every ancestor, so names cost the depth each: 1,000 `<b>`s
    /// of 100 names under 500 `div`s took 6.3 s to make and 7.5 s more to
    /// remove the names, in a Release build (0.6 s under 5 `div`s). The
    /// tree's measured depth decides it, after the parse.
    /// Revert-check: `attributeWalkRefusal` in `admittedParse` (the body is
    /// admitted).
    func testParseDocument_manyNamesDeepInTheTree_isRefusedAsTooCostly() {
        var html = String(repeating: "<div>", count: 500)
        for tag in 0..<1_000 {
            html += "<b" + (0..<100).map { " on\(tag)x\($0)=1" }.joined() + "></b>"
        }
        let cost = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
        XCTAssertLessThanOrEqual(cost.depth, EmailDOMParseAdmission.maximumDepth)
        XCTAssertNil(cost.excessWork)
        XCTAssertGreaterThanOrEqual(cost.attributeNames, 100_000)
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html)) { error in
            guard case let .tooCostlyToParse(work, limit) = error as? EmailDOMParseRefusal else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(limit, EmailDOMParseAdmission.maximumAttributeWalkWork)
            XCTAssertGreaterThanOrEqual(work, 500 * 100_000)
        }
    }

    /// Where the scan's bound sends a body to the measuring thread, the
    /// walks are checked against the depth measured there: refused where
    /// the tree is deep, and admitted where only the bound is (here, forms
    /// inside a form, which SwiftSoup ignores and the scan cannot be sure
    /// of: 1,000 give a bound of 1,007 over a tree 5 deep), however many
    /// names it holds.
    /// Revert-check: `attributeWalkRefusal` in `parseOnMeasuringThread`
    /// (`deep` is admitted), and passing it the bound in place of the
    /// measured depth (`shallow` is refused).
    func testParseOnMeasuringThread_attributeWalks_followTheMeasuredDepth() throws {
        let unsureForms = String(repeating: "<form>x", count: 1_000)
        var deep = String(repeating: "<div>", count: 330) + unsureForms
        for tag in 0..<300 {
            deep += "<b" + (0..<100).map { " n\(tag)x\($0)=1" }.joined() + "></b>"
        }
        var shallow = unsureForms + "<table>"
        for row in 0..<2_000 {
            shallow += "<tr><td" + (0..<12).map { " a\(row)x\($0)=1" }.joined() + ">x</td></tr>"
        }
        shallow += "</table>"
        for html in [deep, shallow] {
            let cost = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
            XCTAssertGreaterThan(cost.depth, EmailDOMParseAdmission.maximumDepth)
            XCTAssertLessThanOrEqual(cost.depth, EmailDOMParseAdmission.maximumBoundForMeasuredParse)
            XCTAssertNil(cost.excessWork)
        }
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(deep), "deep") { error in
            guard case let .tooCostlyToParse(_, limit) = error as? EmailDOMParseRefusal else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(limit, EmailDOMParseAdmission.maximumAttributeWalkWork)
        }
        XCTAssertNoThrow(try EmailDOMParseAdmission.parseDocument(shallow), "shallow")
    }

    /// A formatting element SwiftSoup rebuilds is copied with its names, in
    /// the parse, where no walk is made; the sanitizer then removes every
    /// copy's `on…` names, each removal a walk up its ancestors. 400 `div`s,
    /// a `b` of 20 `on…` names closed by `</p>`, then `<p>y</p>`s, each
    /// rebuilding it (10,000 of them: 12.7 s of removals in a Release build,
    /// from 20 names read). A vertical tab before a name is trimmed, so it
    /// is still removed. Other names a copy is given walk nowhere in a
    /// document's parse.
    /// Revert-check: `rebuildNamesAcrossTokens` in `estimate(in:limit:…)`'s
    /// copied names (both are admitted), and the vertical tab's skip in
    /// `endOfAttributes` (the second is).
    func testParseDocument_eventNamesCopiedByRebuilds_areCountedForTheirWalks() {
        func body(_ prefix: String) -> String {
            String(repeating: "<div>", count: 400)
                + "<p><b" + (0..<20).map { " \(prefix)\($0)=1" }.joined() + ">x</p>"
                + String(repeating: "<p>y</p>", count: 1_000)
        }
        for events in [body("on"), body("\u{0B}on")] {
            let cost = EmailDOMParseAdmission.estimatedCost(of: events, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
            XCTAssertNil(cost.excessWork)
            XCTAssertGreaterThan(cost.attributeNames, 20 * 1_000)
            XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(events)) { error in
                guard case let .tooCostlyToParse(_, limit) = error as? EmailDOMParseRefusal else {
                    return XCTFail("\(error)")
                }
                XCTAssertEqual(limit, EmailDOMParseAdmission.maximumAttributeWalkWork)
            }
        }
        XCTAssertEqual(EmailDOMParseAdmission.estimatedCost(of: body("class")).attributeNames, 20)
    }

    /// A fragment is parsed without SwiftSoup's bulk building, so a rebuilt
    /// copy is given its names once it is in the tree, each a walk up its
    /// ancestors inside the parse, whatever the names: a `b` of 100 names
    /// under 400 `div`s rebuilt 1,000 times took 6.4 s in
    /// `parseBodyFragment` and 0.2 s in `parseDocument` (Release). Charged
    /// in `treeWork`, for a fragment only.
    /// Revert-check: the fragment term of `treeWork` in
    /// `estimate(in:limit:…)` (the fragment is admitted).
    func testParseBodyFragment_namesOfRebuiltCopies_areChargedInTheParse() {
        let html = String(repeating: "<div>", count: 400)
            + "<p><b" + (0..<100).map { " class\($0)=1" }.joined() + ">x</p>"
            + String(repeating: "<p>y</p>", count: 1_000)
        let limit = EmailDOMParseAdmission.maximumBoundForMeasuredParse
        let fragment = EmailDOMParseAdmission.estimatedCost(of: html, limit: limit, readsHead: false)
        let document = EmailDOMParseAdmission.estimatedCost(of: html, limit: limit)
        XCTAssertGreaterThan(fragment.treeWork, EmailDOMParseAdmission.maximumTreeWork)
        XCTAssertLessThanOrEqual(document.treeWork, EmailDOMParseAdmission.maximumTreeWork)
        XCTAssertThrowsError(try EmailDOMParseAdmission.parseBodyFragment(html)) { error in
            XCTAssertEqual(
                error as? EmailDOMParseRefusal,
                .tooCostlyToParse(work: fragment.treeWork, limit: EmailDOMParseAdmission.maximumTreeWork)
            )
        }
    }

    /// SwiftSoup takes a tag for the run of its name after the last NUL
    /// when that run has no uppercase letter (`readTagName` sets the tag's
    /// identity from each run): `<x\0html a>` gives the root `a`, as
    /// `<html a>` does, and `<x\0select>` is a `select`. A run with an
    /// uppercase letter, or none, or one that is not among SwiftSoup's
    /// `TagId` names leaves the tag unknown, an element that stays open:
    /// `<y\0link>` × 50,000 nests 50,000 deep, and `<y\0x></x>` is never
    /// closed by its end tag.
    /// Revert-check: the last run in `TokenizingScanner.readTag` (the first
    /// two are admitted, and `select` is not read), the `swiftSoupTagIds`
    /// check there (the deep ones are bounded low), and the NUL in
    /// `AttributeWorkBound.rootTagNameEnds` (the third is admitted).
    func testParseDocument_tagNamedAfterANul_isReadAsSwiftSoupReadsIt() {
        let tags = (0..<4_000).map { " a\($0) b\($0) c\($0) d\($0)>" }
        let shapes = [
            "<html><body>x" + tags.map { "<x\u{0}html" + $0 }.joined(),
            "<html><body>x" + tags.map { "<Y\u{0}\u{0}body" + $0 }.joined(),
            "<html><body>x" + tags.map { "<x\u{0}html" + $0 }.joined() + "<select>",
        ]
        for html in shapes {
            let cost = EmailDOMParseAdmission.estimatedCost(of: html, limit: EmailDOMParseAdmission.maximumBoundForMeasuredParse)
            XCTAssertGreaterThan(cost.rootAttributeMergeWork, EmailDOMParseAdmission.maximumRootAttributeMergeWork)
            XCTAssertThrowsError(try EmailDOMParseAdmission.parseDocument(html))
        }
        XCTAssertEqual(
            EmailDOMParseAdmission.estimatedCost(of: "<html><body>x<x\u{0}html a b>").rootAttributeMergeWork,
            EmailDOMParseAdmission.estimatedCost(of: "<html><body>x<html a b>").rootAttributeMergeWork
        )
        XCTAssertEqual(EmailDOMParseAdmission.estimatedCost(of: "<html><body>x<x\u{0}HTML a b>").rootAttributeMergeWork, 0)
        XCTAssertEqual(EmailDOMParseAdmission.estimatedCost(of: "<html><body>x<x\u{0}html\u{0} a b>").rootAttributeMergeWork, 0)
        XCTAssertFalse(EmailDOMParseAdmission.followedTokenizedDepthEstimate(of: "<p><x\u{0}select><b>").followed)
        XCTAssertTrue(EmailDOMParseAdmission.followedTokenizedDepthEstimate(of: "<p><x\u{0}SELECT><b>").followed)

        let unknownRuns = [
            String(repeating: "<y\u{0}link>", count: 1_000),
            String(repeating: "<y\u{0}x></x>", count: 1_000),
            "<y\u{0}link><noscript>" + String(repeating: "<div>", count: 1_000),
            String(repeating: "<y\u{0}font>", count: 1_000),
        ]
        for html in unknownRuns {
            XCTAssertGreaterThanOrEqual(EmailDOMParseAdmission.estimatedDepth(of: html), 1_000, html.debugDescription.prefix(30).description)
        }
    }

    /// Attribute-heavy mail is charged far below the limit: a newsletter of
    /// 2,000 cells each with a dozen attributes, and the shapes item 2b
    /// measured (`<head`, `<br` and `<a` run together are one tag name each).
    func testAttributeDedupWork_ordinaryAttributeHeavyMail_isAdmitted() throws {
        var newsletter = "<html><body><table>"
        for row in 0..<2_000 {
            newsletter += "<tr><td align=\"left\" valign=\"top\" width=\"600\" height=\"20\" bgcolor=\"#ffffff\" class=\"c\(row)\" id=\"r\(row)\" style=\"padding:0\" dir=\"ltr\" role=\"presentation\" data-a=\"1\" data-b=\"2\">row \(row)</td></tr>"
        }
        newsletter += "</table></body></html>"
        let shapes = [
            newsletter,
            "<html lang=\"en\" dir=\"ltr\" xmlns=\"http://www.w3.org/1999/xhtml\"><head></head>"
                + "<body style=\"margin:0\" bgcolor=\"#ffffff\" class=\"body\" link=\"#000\" vlink=\"#000\">"
                + newsletter,
            "<html><body>" + String(repeating: "<head", count: 8_000) + "</body></html>",
            String(repeating: "<br", count: 8_000),
            String(repeating: "<a", count: 8_000),
        ]
        for html in shapes {
            let cost = EmailDOMParseAdmission.estimatedCost(of: html)
            XCTAssertLessThan(cost.attributeDedupWork, EmailDOMParseAdmission.maximumAttributeDedupWork / 100, String(html.prefix(60)))
            XCTAssertLessThan(cost.rootAttributeMergeWork, EmailDOMParseAdmission.maximumRootAttributeMergeWork / 100, String(html.prefix(60)))
            XCTAssertLessThan(cost.treeWork, EmailDOMParseAdmission.maximumTreeWork / 10, String(html.prefix(60)))
            XCTAssertNil(
                EmailDOMParseAdmission.attributeWalkRefusal(depth: cost.depth, attributeNames: cost.attributeNames),
                String(html.prefix(60))
            )
            XCTAssertNoThrow(try EmailDOMParseAdmission.parseDocument(html), String(html.prefix(60)))
        }
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

    // MARK: - SwiftSoup's tokenizer overread

    /// Bodies ending where SwiftSoup 2.13.5 reads past the end of its input
    /// (a stale UTF-8 decoder in `consumeLetterSequenceSlice`), each of
    /// which trapped the parse (measured): an end tag name in raw text or
    /// script data, after text outside ASCII too, a script's double escape,
    /// a doctype's name, and a trailing space read over.
    private static let overreadingBodies = [
        "<style></a\u{E9}x\u{E9}",
        "<script><!--<script\u{E9}x\u{E9}",
        "<noframes></xx\u{E9}x\u{E9}",
        "<script></ax\u{3A9}\u{3A9}\u{65E5} ",
        "<style>a</a\u{436}a\u{E9}",
        "<p>Hello</p><title><!--</script\u{E9}x\u{E9}",
        "<style>\u{E9}</a\u{E9}x\u{E9}",
        "<script>\"\u{E9}\"</a\u{E9}x\u{E9}",
        "<!DOCTYPE a\u{E9}a\u{E9}",
        "<p>Hello</p><!DOCTYPE html\u{E9}x\u{E9}",
    ]

    /// Revert-check: `paddedAgainstTheTokenizerOverread` in the three parse
    /// entry points (without it each of these crashes the test host).
    func testParse_bodyEndingWhereTheTokenizerOverreads_parsesWithoutTrapping() throws {
        let context = try Element(Tag.valueOf("tr"), "")
        for html in Self.overreadingBodies {
            XCTAssertNoThrow(try EmailDOMParseAdmission.parseDocument(html), html.debugDescription)
            XCTAssertNoThrow(try EmailDOMParseAdmission.parseBodyFragment(html), html.debugDescription)
            XCTAssertNoThrow(try EmailDOMParseAdmission.parseFragment(html, context: context), html.debugDescription)
        }
    }

    /// Only a body whose last four bytes hold one outside ASCII is padded,
    /// and the padding changes no text a reader sees. HONEST SCOPE: `text()`
    /// trims whitespace, so the text comparison holds for any padding of
    /// spaces; what pins the padding is the `html + "    "` check.
    func testPadding_bodiesEndingInTextOutsideASCII_readTheSame() throws {
        XCTAssertEqual(EmailDOMParseAdmission.paddedAgainstTheTokenizerOverread("<p>Caf\u{E9}</p>"), "<p>Caf\u{E9}</p>")
        XCTAssertEqual(EmailDOMParseAdmission.paddedAgainstTheTokenizerOverread("plain"), "plain")
        let bodies = [
            "Merci, \u{E0} bient\u{F4}t \u{E9}t\u{E9}",
            "<p>a<b>\u{E9}t\u{E9}",
            "<div title=\"\u{E9}x\u{E9}\">\u{65E5}\u{672C}",
            "<p>\u{65E5}\u{672C}\u{8A9E}",
        ]
        for html in bodies {
            XCTAssertEqual(EmailDOMParseAdmission.paddedAgainstTheTokenizerOverread(html), html + "    ")
            let padded = try EmailDOMParseAdmission.parseDocument(html)
            let plain = try SwiftSoup.parse(html)
            XCTAssertEqual(try padded.text(), try plain.text(), html.debugDescription)
        }
    }

    /// A message whose body ends this way is processed and kept with its
    /// body and its text.
    /// HONEST SCOPE: without the padding this test crashes rather than fails.
    func testProcessGmailMessage_bodyEndingWhereTheTokenizerOverreads_persistsTheBody() async throws {
        let html = "<p>Hello there</p><style></a\u{E9}x\u{E9}"
        let message = GmailMessage(
            id: "overread-html",
            threadId: "overread-html-thread",
            labelIds: ["INBOX"],
            snippet: "Hello there",
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
        XCTAssertEqual(processed.chatPreviewText.map { $0.contains("Hello there") }, true)
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
            XCTAssertNoThrow(try EmailDOMParseAdmission.parseDocument(html), String(html.prefix(120)))
            XCTAssertLessThan(EmailDOMParseAdmission.tokenizedDepthEstimate(of: html), 100, String(html.prefix(120)))
        }
    }

    func testOrdinaryShapes_areAdmitted() {
        // A reply chain of 120 Gmail-quoted replies nests about 360 deep.
        var chain = "<div dir=\"ltr\">latest</div>"
        for index in 0..<120 {
            chain = "<div dir=\"ltr\">reply \(index)</div><div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">On a day, someone wrote:<br></div><blockquote class=\"gmail_quote\" style=\"margin:0 0 0 .8ex\">" + chain + "</blockquote></div>"
        }
        XCTAssertNoThrow(try EmailDOMParseAdmission.parseDocument(chain))

        // A large old-style newsletter: thousands of tags, unclosed cells,
        // fonts and list items, conditional comments and a commented style
        // sheet.
        var newsletter = "<html><head><style><!-- td { color: red } --></style></head><body>"
        for row in 0..<300 {
            newsletter += "<!--[if mso]><table><tr><td><![endif]--><table><tr><td><font face=Arial>row \(row)<td>cell<tr><td><ul><li>a<li>b</ul></table><!--[if mso]></td></tr></table><![endif]--><p>para<p>next"
        }
        newsletter += "</body></html>"
        XCTAssertNoThrow(try EmailDOMParseAdmission.parseDocument(newsletter))
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
        switch below(12) {
        case 0: return name.uppercased()
        case 1: return name.prefix(1).uppercased() + name.dropFirst()
        // SwiftSoup takes the tag for the run after a NUL in its name when
        // that run has no uppercase letter.
        case 2: return "x\u{0}" + name
        case 3: return pick(["x", "X\u{0}y", "b"]) + "\u{0}" + name.uppercased()
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
