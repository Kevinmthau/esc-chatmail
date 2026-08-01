import XCTest
@testable import esc_chatmail

/// CX5 characterization: the "quoted+signatures → quoted-only → original
/// HTML" degradation chain, each step guarded by
/// `HTMLMeaningfulContentChecker.hasMeaningfulContent`. Pins the chain's
/// behavior on the three fixture classes (content survives full cleanup /
/// survives only quoted-only / survives no mode) and asserts the
/// `prepareHTMLForDisplay` seam agrees with the canonical helper, so the
/// former copies cannot desynchronize.
final class HTMLCleanupFallbackTests: XCTestCase {

    /// Body content plus a quoted reply: full cleanup keeps the body.
    private let survivesFullCleanupHTML = """
    <p>Fresh body content for today.</p>
    <div class="gmail_quote"><p>Original quoted content</p></div>
    """

    /// Signature-only content: signature removal wipes it, quoted-only keeps it.
    private let survivesOnlyQuotedOnlyHTML = """
    <div class="gmail_signature">--<br>Sent from my iPhone</div>
    """

    /// Quote-only content: both modes wipe it; the original must come back.
    private let survivesNoModeHTML = """
    <div class="gmail_quote"><p>Original quoted content</p></div>
    """

    // MARK: - Canonical helper

    func testChain_contentSurvivingFullCleanup_appliesFirstMode() {
        let result = HTMLCleanupFallback.cleanedHTML(
            from: survivesFullCleanupHTML,
            modes: [.quotedAndSignatures, .quotedOnly]
        )

        XCTAssertEqual(result.appliedMode, .quotedAndSignatures)
        XCTAssertTrue(result.html.contains("Fresh body content"), "Unexpected html: \(result.html)")
        XCTAssertFalse(result.html.contains("Original quoted content"), "Unexpected html: \(result.html)")
    }

    func testChain_signatureOnlyContent_fallsBackToQuotedOnly() {
        let result = HTMLCleanupFallback.cleanedHTML(
            from: survivesOnlyQuotedOnlyHTML,
            modes: [.quotedAndSignatures, .quotedOnly]
        )

        XCTAssertEqual(result.appliedMode, .quotedOnly)
        XCTAssertTrue(result.html.contains("Sent from my iPhone"), "Unexpected html: \(result.html)")
    }

    func testChain_quoteOnlyContent_fallsBackToOriginal() {
        let result = HTMLCleanupFallback.cleanedHTML(
            from: survivesNoModeHTML,
            modes: [.quotedAndSignatures, .quotedOnly]
        )

        XCTAssertNil(result.appliedMode)
        XCTAssertEqual(result.html, survivesNoModeHTML)
    }

    func testChain_singleModeList_fallsBackToOriginalWhenWiped() {
        let result = HTMLCleanupFallback.cleanedHTML(
            from: survivesNoModeHTML,
            modes: [.quotedOnly]
        )

        XCTAssertNil(result.appliedMode)
        XCTAssertEqual(result.html, survivesNoModeHTML)
    }

    /// Apple-Mail-shaped bottom-post: attribution line and quoted history
    /// first, the author's text after. Marker truncation wipes it under both
    /// full modes; the containers-only mode keeps the trailing content.
    func testChain_bottomPostedReply_quotedContainersOnlyRecoversContent() {
        let bottomPostedHTML = """
        <div>On Aug 1, 2026, at 9:00 AM, Olga wrote:</div>
        <blockquote type="cite"><div>Quoted history line</div></blockquote>
        <div>Bottom-posted reply text</div>
        """

        let result = HTMLCleanupFallback.cleanedHTML(
            from: bottomPostedHTML,
            modes: [.quotedAndSignatures, .quotedOnly, .quotedContainersOnly]
        )

        XCTAssertEqual(result.appliedMode, .quotedContainersOnly)
        XCTAssertTrue(result.html.contains("Bottom-posted reply text"), "Unexpected html: \(result.html)")
        XCTAssertFalse(result.html.contains("Quoted history line"), "Unexpected html: \(result.html)")
    }

    /// Marker-only quote with NO container: there is no boundary between the
    /// quoted history and content, so the containers-only mode must decline
    /// and the chain must fall back to the original (which then goes through
    /// full plain-text quote removal).
    func testChain_markerOnlyQuoteWithoutContainer_fallsBackToOriginal() {
        let markerOnlyHTML = """
        <div>On Jan 31, 2026 at 12:31 PM, Scott Wunderlich wrote:</div>
        <div>Earlier message only.</div>
        """

        let result = HTMLCleanupFallback.cleanedHTML(
            from: markerOnlyHTML,
            modes: [.quotedAndSignatures, .quotedOnly, .quotedContainersOnly]
        )

        XCTAssertNil(result.appliedMode)
        XCTAssertEqual(result.html, markerOnlyHTML)
    }

    func testChain_emptyInput_returnsOriginal() {
        let result = HTMLCleanupFallback.cleanedHTML(
            from: "",
            modes: [.quotedAndSignatures, .quotedOnly]
        )

        XCTAssertNil(result.appliedMode)
        XCTAssertEqual(result.html, "")
    }

    // MARK: - prepareHTMLForDisplay seam (former copy #2)

    func testPrepareHTMLForDisplay_quotedAndSignature_matchesCanonicalChain() {
        let fixtures = [survivesFullCleanupHTML, survivesOnlyQuotedOnlyHTML, survivesNoModeHTML]

        for html in fixtures {
            let seam = HTMLContentLoader.shared.prepareHTMLForDisplay(html, cleanupMode: .quotedAndSignature)
            let canonical = HTMLCleanupFallback.cleanedHTML(
                from: html,
                modes: [.quotedAndSignatures, .quotedOnly]
            ).html
            XCTAssertEqual(seam, canonical, "prepareHTMLForDisplay diverged from the canonical chain")
        }
    }

    func testPrepareHTMLForDisplay_quotedOnly_matchesCanonicalChain() {
        let fixtures = [survivesFullCleanupHTML, survivesOnlyQuotedOnlyHTML, survivesNoModeHTML]

        for html in fixtures {
            let seam = HTMLContentLoader.shared.prepareHTMLForDisplay(html, cleanupMode: .quotedOnly)
            let canonical = HTMLCleanupFallback.cleanedHTML(from: html, modes: [.quotedOnly]).html
            XCTAssertEqual(seam, canonical, "prepareHTMLForDisplay diverged from the canonical chain")
        }
    }

    func testPrepareHTMLForDisplay_noneMode_returnsInputUntouched() {
        XCTAssertEqual(
            HTMLContentLoader.shared.prepareHTMLForDisplay(survivesNoModeHTML, cleanupMode: .none),
            survivesNoModeHTML
        )
    }
}
