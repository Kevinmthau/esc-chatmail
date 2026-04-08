import XCTest
@testable import esc_chatmail

final class EmailPreviewClassifierTests: XCTestCase {
    private let sut = EmailPreviewClassifier()

    func testClassifyNewsletterHTML_returnsNewsletter() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <p><a href="https://example.com/view">View in browser</a></p>
            <table><tr><td><img src="https://cdn.example.com/hero.jpg" width="640" height="320"></td></tr></table>
            <table><tr><td><img src="https://cdn.example.com/chart-1.jpg" width="320" height="180"></td></tr></table>
            <table><tr><td><img src="https://cdn.example.com/chart-2.jpg" width="320" height="180"></td></tr></table>
            <table><tr><td><img src="https://cdn.example.com/chart-3.jpg" width="320" height="180"></td></tr></table>
            <p><a href="https://example.com/story-1">Story one</a></p>
            <p><a href="https://example.com/story-2">Story two</a></p>
            <p><a href="https://example.com/story-3">Story three</a></p>
            <p><a href="https://example.com/story-4">Story four</a></p>
            <p><a href="https://example.com/story-5">Story five</a></p>
            <p><a href="https://example.com/story-6">Story six</a></p>
            <p><a href="https://example.com/story-7">Story seven</a></p>
            <p><a href="https://example.com/story-8">Story eight</a></p>
            <p><a href="https://example.com/story-9">Story nine</a></p>
            <p><a href="https://example.com/story-10">Story ten</a></p>
            <p><a href="https://example.com/story-11">Story eleven</a></p>
            <p>Manage preferences or unsubscribe at any time.</p>
        </body>
        </html>
        """

        let result = sut.classify(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "newsletter@morningbrew.com",
            subject: "Daily Brief"
        )

        XCTAssertEqual(result.kind, .newsletter)
        XCTAssertTrue(result.signals.contains(.unsubscribeFooter))
        XCTAssertTrue(result.signals.contains(.manyLinks))
        XCTAssertGreaterThanOrEqual(result.newsletterScore, 55)
    }

    func testClassifyTransactionalHTML_returnsTransactional() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <table>
                <tr><td><strong>Your receipt is ready</strong></td></tr>
                <tr><td>Order confirmation for account activity ending in 4242.</td></tr>
                <tr><td><a href="https://example.com/orders/123">View receipt</a></td></tr>
            </table>
        </body>
        </html>
        """

        let result = sut.classify(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "no-reply@billing.example.com",
            subject: "Order confirmation"
        )

        XCTAssertEqual(result.kind, .transactional)
        XCTAssertTrue(result.signals.contains(.transactionalKeywords))
        XCTAssertTrue(result.signals.contains(.senderNoReply))
    }

    func testClassifyConversationalHTML_returnsPersonToPerson() {
        let html = """
        <div>Hi Kevin,</div>
        <div>Wanted to send over the latest photos from the trip.</div>
        <div>Let me know what you think.</div>
        <div>Thanks,</div>
        <div>Alex</div>
        """

        let result = sut.classify(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "alex@example.com",
            subject: "Re: Trip photos"
        )

        XCTAssertEqual(result.kind, .personToPerson)
        XCTAssertTrue(result.signals.contains(.conversationalGreeting))
    }
}
