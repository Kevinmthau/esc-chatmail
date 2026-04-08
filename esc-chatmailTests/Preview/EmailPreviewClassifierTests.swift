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

    func testClassifyVenmoPaymentHTML_returnsTransactional() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <table>
                <tr><td><img src="https://cdn.venmo.com/promos/cashback-banner.png" width="600" height="240" alt="Earn up to 5% cashback banner"></td></tr>
                <tr><td><h1>You paid Andrew Archer</h1></td></tr>
                <tr><td><p>$100.00</p></td></tr>
                <tr><td><a href="https://venmo.com/story/123">See transaction</a></td></tr>
                <tr><td><h2>Transaction details</h2></td></tr>
                <tr><td>Date</td></tr>
                <tr><td>Apr 08, 2026</td></tr>
                <tr><td>Status</td></tr>
                <tr><td>Pending</td></tr>
                <tr><td>Payment Method</td></tr>
                <tr><td>Venmo balance</td></tr>
            </table>
        </body>
        </html>
        """

        let result = sut.classify(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "venmo@venmo.com",
            subject: "You paid Andrew Archer $100.00"
        )

        XCTAssertEqual(result.kind, .transactional)
        XCTAssertTrue(result.signals.contains(.transactionalKeywords))
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

    func testClassifyInstitutionalSecurityUpdateHTML_returnsNewsletter() {
        let filler = String(repeating: "<p>Security guidance content block.</p>", count: 400)
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <div id="emailPreHeader" style="display:none">Secure your mobile phone in minutes</div>
            <table><tr><td><a href="https://pb.jpmorgan.com/home"><img src="https://pages-pb.jpmorgan.com/logo.png" width="640" height="77" alt="J.P. Morgan Private Bank"></a></td></tr></table>
            <table><tr><td><img src="https://pages-pb.jpmorgan.com/lock.jpg" width="160" height="160" alt="Lock icon"></td><td><h2>Enable extra security at sign-in on mobile</h2><p>Use your device passcode each time for stronger sign-in.</p><a href="https://pb.jpmorgan.com/passcode">Enable device passcode</a></td></tr></table>
            <table><tr><td><img src="https://pages-pb.jpmorgan.com/fingerprint.jpg" width="160" height="160" alt="Fingerprint"></td><td><h2>Use biometrics instead of usernames and passwords</h2><p>Sign in with Face ID or fingerprint for stronger protection.</p><a href="https://pb.jpmorgan.com/biometrics">Turn on biometrics</a></td></tr></table>
            <table><tr><td><img src="https://pages-pb.jpmorgan.com/phone.jpg" width="160" height="160" alt="Mobile phone"></td><td><h2>Sign in regularly to your mobile app to keep your device trusted</h2><p>A trusted device helps us confirm it's you when you call your Client Service team.</p><a href="https://pb.jpmorgan.com/app">Download the app</a></td></tr></table>
            <table><tr><td><h2>Stay one step ahead: Smart habits for stronger mobile security</h2><p>Mobile phones are a prime target for fraud. These tips can help keep your phone safe.</p><a href="https://pb.jpmorgan.com/article">Read article</a></td></tr></table>
            \(filler)
            <table><tr><td><a href="https://pb.jpmorgan.com/privacy">Privacy Policy</a> <a href="https://pb.jpmorgan.com/finra">FINRA</a> <a href="https://pb.jpmorgan.com/sipc">SIPC</a> <a href="https://pb.jpmorgan.com/legal">Important information</a> <a href="https://pb.jpmorgan.com/contact">Contact us</a></td></tr></table>
        </body>
        </html>
        """

        let placeholderPlainText = """
        ${Body-Copy-Text}
        ${Body-Strong-Copy-Text}
        ${Article-Headline}
        """

        let result = sut.classify(
            canonicalHTML: html,
            bodyText: placeholderPlainText,
            senderEmail: "private_banking@pb.jpmorgan.com",
            subject: "Quick steps to strengthen your mobile security"
        )

        XCTAssertEqual(result.kind, .newsletter)
        XCTAssertTrue(result.signals.contains(.manyImages))
        XCTAssertTrue(result.signals.contains(.manyTables))
        XCTAssertTrue(result.signals.contains(.manyLinks))
        XCTAssertTrue(result.signals.contains(.largeHTMLBody))
        XCTAssertTrue(result.signals.contains(.marketingFooter))
    }
}
