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

    // MARK: - Current false positives of `div[class*=sig]`
    //
    // These classes contain the substring "sig" but are not signatures.
    // Today's substring matching removes them — content loss for design/
    // signup/insights/assignment layouts. Pinned here as current behavior;
    // CP1a (token-anchoring the sig selector) flips these to survivals.

    func testCurrentBehavior_designClassIsRemoved_falsePositive() throws {
        let html = "<p>Intro text.</p><div class=\"design-column\">\(mainBody)</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertFalse(text.contains("main message body"), "current substring matching treats de[sig]n as a signature")
    }

    func testCurrentBehavior_signupFormIsRemoved_falsePositive() throws {
        let html = "<p>Intro text.</p><div class=\"signup-form\">Join our newsletter for weekly updates</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertFalse(text.contains("Join our newsletter"), "current substring matching treats [sig]nup as a signature")
    }

    func testCurrentBehavior_insightsClassIsRemoved_falsePositive() throws {
        let html = "<p>Intro text.</p><div class=\"insights\">Market analysis and key takeaways</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertFalse(text.contains("Market analysis"), "current substring matching treats in[sig]hts as a signature")
    }

    func testCurrentBehavior_assignmentListIsRemoved_falsePositive() throws {
        let html = "<p>Intro text.</p><div class=\"assignment-list\">Homework due Friday</div>"
        let text = try visibleText(afterRemovingFootersFrom: html)
        XCTAssertFalse(text.contains("Homework due Friday"), "current substring matching treats as[sig]nment as a signature")
    }
}
