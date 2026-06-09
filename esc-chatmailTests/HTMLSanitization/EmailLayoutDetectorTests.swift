import XCTest
@testable import esc_chatmail

final class EmailLayoutDetectorTests: XCTestCase {
    /// Regression guard for the catastrophic-backtracking blowup that made full-original-email
    /// opens take 20s–2.5min on large newsletters. The CSS width-rule scanners ran their
    /// `([^{}@]+)\{…` prelude regex against the entire HTML body; a large brace-free body made that
    /// regex O(n²) (a single 55KB body measured at 23s; 90KB at 151s). The scanners now read rules
    /// from the extracted `<style>` CSS only, so a large body no longer drives the cost.
    func testFixedWidthDetectionStaysFastOnLargeBody() {
        let filler = String(
            repeating: "<div>Newsletter section with a fair amount of body copy and a <a href=\"https://example.com\">link</a>.</div>\n",
            count: 900
        )
        let html = """
        <!DOCTYPE html><html><head><style>
        .wrapper { max-width: 640px; margin: 0 auto; }
        table.layout { width: 640px; }
        </style></head><body>
        <table class="layout" width="640"><tr><td>Header</td></tr></table>
        \(filler)
        </body></html>
        """
        XCTAssertGreaterThan(html.count, 60_000, "fixture must be large enough to expose the O(n^2) blowup")

        let start = CFAbsoluteTimeGetCurrent()
        let width = EmailLayoutDetector.originalFixedLayoutViewportWidth(in: html)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertEqual(width, 640, "fixed-width layout should still resolve to its authored width")
        // Pre-fix this took 20s+; post-fix it is tens of ms. A generous 2s bound reliably catches a
        // reintroduced O(n^2) scan without flaking on a loaded CI machine.
        XCTAssertLessThan(elapsed, 2.0, "fixed-layout detection regressed toward O(n^2) (took \(elapsed)s)")
    }

    /// CSS rules (`selector { … }`) are read from `<style>` blocks, not from body content. A
    /// brace-bearing `table { max-width: … }` sitting in body text (e.g. an example in a `<pre>`)
    /// must NOT be honored as a layout rule. The pre-fix full-document scan would have matched the
    /// body rule (880) and returned it; scanning only `<style>` CSS now yields the real table's 700.
    func testCSSRuleInBodyTextIsNotTreatedAsRule() {
        let html = """
        <html><body>
        <pre>Example: table { max-width: 880px } sets a cap.</pre>
        <table width="700"><tr><td>Real fixed-width layout</td></tr></table>
        </body></html>
        """
        XCTAssertEqual(EmailLayoutDetector.originalFixedLayoutViewportWidth(in: html), 700)
    }

    /// A `max-width` table rule authored in a `<style>` block is honored.
    func testMaxWidthRuleInStyleBlockIsDetected() {
        let html = """
        <!DOCTYPE html><html><head><style>
        table { max-width: 600px; }
        </style></head><body>
        <table><tr><td>Capped layout</td></tr></table>
        </body></html>
        """
        XCTAssertEqual(EmailLayoutDetector.originalFixedLayoutViewportWidth(in: html), 600)
    }

    /// An unclosed `<style>` (no `</style>`) must still have its rules read — browsers treat the
    /// remainder of the document as stylesheet content, and the prior full-document scan did too.
    func testRuleInUnclosedStyleBlockIsStillDetected() {
        let html = """
        <!DOCTYPE html><html><head><style>
        table { max-width: 600px; }
        <body>
        <table><tr><td>Capped layout, malformed (unclosed style)</td></tr></table>
        </body></html>
        """
        XCTAssertFalse(html.contains("</style>"), "fixture must keep the <style> unclosed")
        XCTAssertEqual(EmailLayoutDetector.originalFixedLayoutViewportWidth(in: html), 600)
    }
}
