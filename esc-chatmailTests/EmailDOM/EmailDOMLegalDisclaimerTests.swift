import XCTest
@testable import esc_chatmail

/// Pins the guards of `EmailDOMQuoteRemover.truncateTrailingLegalDisclaimer`. What the
/// bubble shows is pinned by the golden corpus (`html_front_trailing_disclaimer_*` and
/// its neighbours); these cover what the corpus's text comparison cannot see.
final class EmailDOMLegalDisclaimerTests: XCTestCase {
    private let disclaimer = "This communication is confidential and intended solely for the use of the addressee(s). " +
        "If you are not an addressee, please notify the sender and delete this message."

    // Revert-check: the containsMediaAfterSignature guard in truncateTrailingLegalDisclaimer.
    func testRemoveQuotes_authoredImageAfterDisclaimer_keepsDisclaimerAndImage() {
        let html = "<p>Here are the photos.</p><p>\(disclaimer)</p><p><img src=\"cid:photo\" width=\"1600\" height=\"1200\"></p>"
        let cleaned = EmailDOMQuoteRemover.removeQuotes(from: html) ?? ""
        XCTAssertTrue(cleaned.contains("cid:photo"))
        XCTAssertTrue(cleaned.contains("If you are not an addressee"))
    }

    func testRemoveQuotes_trackingPixelAfterDisclaimer_removesDisclaimer() {
        let html = "<p>Here are the photos.</p><p>\(disclaimer)</p>" +
            "<img src=\"https://t.example/p.gif\" width=\"1\" height=\"1\" aria-hidden=\"true\">"
        let cleaned = EmailDOMQuoteRemover.removeQuotes(from: html) ?? ""
        XCTAssertTrue(cleaned.contains("Here are the photos."))
        XCTAssertFalse(cleaned.contains("addressee"))
    }

    /// The disclaimer goes in `.quotedAndSignatures` alone: `.quotedOnly` is the fallback
    /// chain's rescue for a message the full cleanup emptied, and keeps it.
    func testRemoveQuotes_quotedOnlyMode_keepsDisclaimer() {
        let html = "<p>Reply.</p><p>\(disclaimer)</p>"
        XCTAssertFalse((EmailDOMQuoteRemover.removeQuotes(from: html) ?? "").contains("addressee"))
        XCTAssertTrue((EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedOnly) ?? "").contains("addressee"))
    }

    /// A disclaimer that is the whole message is left to the fallback chain, which keeps
    /// it rather than showing an empty bubble.
    func testRemoveQuotes_disclaimerIsTheWholeMessage_keepsIt() {
        let html = "<p>\(disclaimer)</p>"
        XCTAssertTrue((EmailDOMQuoteRemover.removeQuotes(from: html) ?? "").contains("addressee"))
    }

    /// The disclaimer is cut inside its own paragraph when a `<br>` line in the same block
    /// is authored text: only the disclaimer's line and what follows it go.
    func testRemoveQuotes_disclaimerAfterBreakInSameBlock_keepsTheLineAbove() {
        let html = "<div>Thanks for the update.<br><br>\(disclaimer)</div>"
        let cleaned = EmailDOMQuoteRemover.removeQuotes(from: html) ?? ""
        XCTAssertTrue(cleaned.contains("Thanks for the update."))
        XCTAssertFalse(cleaned.contains("addressee"))
    }
}
