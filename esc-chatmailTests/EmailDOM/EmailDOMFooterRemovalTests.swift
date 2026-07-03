import XCTest
import SwiftSoup
@testable import esc_chatmail

/// Characterization tests for `EmailDOMQuoteRemover.removeFooterContainers`.
///
/// This function had zero direct coverage; these tests pin its behavior
/// before any selector change. Two groups:
/// - "must remove": real footer/social/unsubscribe/signature markup that
///   every selector revision must keep removing (including camelCase,
///   underscore, and hyphen class-name templates — token-anchoring the
///   broad selectors would regress these).
/// - "current false positives": classes that merely contain the substring
///   `sig` (`design`, `signup-form`, `insights`, `assignment-list`). They
///   document today's substring matching and are expected to flip to
///   survivals when the `sig` selector becomes token-anchored (CP1a).
final class EmailDOMFooterRemovalTests: XCTestCase {

    // MARK: - Helpers

    private let mainBody = "This is the main message body with plenty of visible text that the reader actually cares about."

    private func visibleText(afterRemovingFootersFrom html: String) throws -> String {
        let document = try SwiftSoup.parse(html)
        try EmailDOMQuoteRemover.removeFooterContainers(in: document)
        return try document.text()
    }

    // MARK: - Must remove: footer classes across naming templates

    func testRemovesFooterContainerCamelCase() throws {
        let html = "<p>\(mainBody)</p><div class=\"footerContainer\">Unsubscribe | Preferences</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("Unsubscribe | Preferences"))
    }

    func testRemovesFooterWrapUnderscore() throws {
        let html = "<p>\(mainBody)</p><div class=\"footer_wrap\">Company address line</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("Company address line"))
    }

    func testRemovesEmailFooterHyphen() throws {
        let html = "<p>\(mainBody)</p><div class=\"email-footer\">You received this because…</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("You received this because"))
    }

    func testRemovesPlainFooterClass() throws {
        let html = "<p>\(mainBody)</p><div class=\"footer\">© 2026 Example Corp</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("Example Corp"))
    }

    func testRemovesFooterTable() throws {
        let html = "<p>\(mainBody)</p><table class=\"templateFooter\"><tr><td>Footer cell content</td></tr></table>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("Footer cell content"))
    }

    func testRemovesFooterById() throws {
        let html = "<p>\(mainBody)</p><div id=\"footerSection\">Legal disclaimer text</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("Legal disclaimer text"))
    }

    func testRemovalIsCaseInsensitive() throws {
        let html = "<p>\(mainBody)</p><div class=\"FooterContainer\">Mixed case footer</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("Mixed case footer"))
    }

    // MARK: - Must remove: social and unsubscribe blocks

    func testRemovesSocialLinksDiv() throws {
        let html = "<p>\(mainBody)</p><div class=\"social_links\">Facebook Twitter Instagram</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("Facebook Twitter Instagram"))
    }

    func testRemovesSocialTable() throws {
        let html = "<p>\(mainBody)</p><table class=\"socialShare\"><tr><td>Share on social media</td></tr></table>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("Share on social media"))
    }

    func testRemovesUnsubscribeDivAndParagraph() throws {
        let html = """
        <p>\(mainBody)</p>
        <div class="unsubscribe_link">Click here to unsubscribe</div>
        <p class="unsubscribeText">Manage your email preferences</p>
        """
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("Click here to unsubscribe"))
        XCTAssertFalse(text.contains("Manage your email preferences"))
    }

    // MARK: - Must remove: genuine signature blocks

    func testRemovesSignatureDiv() throws {
        let html = "<p>\(mainBody)</p><div class=\"signature\">John Doe, VP of Sales, 555-1234</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("VP of Sales"))
    }

    func testRemovesSigDiv() throws {
        let html = "<p>\(mainBody)</p><div class=\"sig\">Sent from my phone — Jane</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("Sent from my phone"))
    }

    func testRemovesEmailSignatureHyphenatedDiv() throws {
        let html = "<p>\(mainBody)</p><div class=\"email-signature\">Best regards, The Team</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("Best regards, The Team"))
    }

    func testRemovesSignatureTable() throws {
        let html = "<p>\(mainBody)</p><table class=\"signatureBlock\"><tr><td>Contact card signature</td></tr></table>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("Contact card signature"))
    }

    // MARK: - Non-matching content is untouched

    func testLeavesUnrelatedContentAlone() throws {
        let html = "<div class=\"content\"><p>\(mainBody)</p></div><div class=\"header\">Weekly digest</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertTrue(text.contains("Weekly digest"))
    }

    // MARK: - `sig` false positives fixed by token matching
    //
    // These classes contain the substring "sig" but are not signatures
    // (de[sig]n, [sig]nup, in[sig]hts, as[sig]nment). The old substring
    // selector removed them — real content loss; token-anchored matching
    // must let them survive.

    func testDesignClassSurvives() throws {
        let html = "<p>Intro text.</p><div class=\"design-column\">\(mainBody)</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
    }

    func testSignupFormSurvives() throws {
        let html = "<p>Intro text.</p><div class=\"signup-form\">Join our newsletter for weekly updates</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("Join our newsletter"))
    }

    func testInsightsClassSurvives() throws {
        let html = "<p>Intro text.</p><div class=\"insights\">Market analysis and key takeaways</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("Market analysis"))
    }

    func testAssignmentListSurvives() throws {
        let html = "<p>Intro text.</p><div class=\"assignment-list\">Homework due Friday</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("Homework due Friday"))
    }

    // MARK: - Token-anchored signature matching still removes real signatures

    func testRemovesSignatureTokenAmongMultipleClasses() throws {
        let html = "<p>\(mainBody)</p><div class=\"wrapper email signature compact\">Jane Doe · 555-1234</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("Jane Doe"))
    }

    func testRemovesUnderscoreSeparatedSigToken() throws {
        let html = "<p>\(mainBody)</p><div class=\"mail_sig\">Sent from my tablet</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("main message body"))
        XCTAssertFalse(text.contains("Sent from my tablet"))
    }

    // MARK: - Majority-text guard
    //
    // A matched container holding the majority of the document's visible
    // text is the message, not a footer; removing it wiped the bubble and
    // triggered the downstream empty-content fallback chain.

    func testFooterClassedElementHoldingMajorityOfTextSurvives() throws {
        let longBody = String(repeating: "Meaningful message text that the reader needs. ", count: 10)
        let html = "<p>Hi!</p><div class=\"footerContainer\">\(longBody)</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("Meaningful message text"))
    }

    func testSignatureTokenElementHoldingMajorityOfTextSurvives() throws {
        let longBody = String(repeating: "Actual reply content the sender wrote for the reader. ", count: 10)
        let html = "<p>Hey.</p><div class=\"sig\">\(longBody)</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("Actual reply content"))
    }

    func testFooterOnlyDocumentIsPreservedRatherThanWiped() throws {
        let html = "<div class=\"footer\">The entire message lives inside a footer-classed wrapper.</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("entire message"))
    }

    func testHeroImageOnlyNewsletterFooterStillRemoved() throws {
        // No visible text anywhere: the guard has nothing to protect and
        // image-bearing footer blocks are still removed.
        let html = "<div class=\"hero\"><img src=\"https://example.com/hero.png\"></div><div class=\"footer\"><img src=\"https://example.com/social.png\"></div>"
        let document = try SwiftSoup.parse(html)
        try EmailDOMQuoteRemover.removeFooterContainers(in: document)
        XCTAssertEqual(try document.select("div.footer").array().count, 0)
        XCTAssertEqual(try document.select("div.hero img").array().count, 1)
    }

    func testMinorityTrailingFooterStillRemovedNearBoundary() throws {
        // Footer share ~33% — well under the guard's majority threshold.
        let html = "<p>Sixty characters of real message body text goes right here.</p><div class=\"footer\">Unsubscribe · Preferences · Help</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertTrue(text.contains("real message body"))
        XCTAssertFalse(text.contains("Unsubscribe"))
    }
}
