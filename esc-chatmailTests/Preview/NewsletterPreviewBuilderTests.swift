import XCTest
@testable import esc_chatmail

final class NewsletterPreviewBuilderTests: XCTestCase {
    private let sut = NewsletterPreviewBuilder()

    func testBuildPreview_extractsHeroTitleAndSnippet() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.example.com/logo.png" width="48" height="48" alt="Logo">
            <img src="https://cdn.example.com/hero-banner.jpg" width="640" height="320" alt="Hero banner">
            <h1>Markets are back in motion</h1>
            <p>Stocks rallied sharply after fresh inflation data came in below expectations.</p>
            <p>Here is what matters today, what moved overnight, and what to watch next.</p>
            <p><a href="https://example.com/read-more">Read more</a></p>
            <p>Manage preferences or unsubscribe at any time.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "news@morningbrew.com",
            subject: "Morning Brew"
        )

        XCTAssertEqual(result?.title, "Markets are back in motion")
        XCTAssertEqual(result?.heroImageURL, "https://cdn.example.com/hero-banner.jpg")
        XCTAssertEqual(result?.sourceDomain, "morningbrew.com")
        XCTAssertTrue(result?.snippet.contains("Stocks rallied sharply") == true)
        XCTAssertFalse(result?.snippet.lowercased().contains("unsubscribe") == true)
    }

    func testBuildPreview_fallsBackToSubjectAndStopsBeforeFooter() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <p>Top analysis from our editors, selected for this week's issue.</p>
            <p>Three trends are driving the market and the first one is already underway.</p>
            <p>View in browser</p>
            <p>Privacy policy</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "dispatch@weekly-ledger.com",
            subject: "Weekly Dispatch"
        )

        XCTAssertEqual(result?.title, "Weekly Dispatch")
        XCTAssertEqual(result?.sourceDomain, "weekly-ledger.com")
        XCTAssertTrue(result?.snippet.contains("Top analysis from our editors") == true)
        XCTAssertFalse(result?.snippet.lowercased().contains("privacy policy") == true)
    }
}
