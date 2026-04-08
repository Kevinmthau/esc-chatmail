import XCTest
@testable import esc_chatmail

final class TransactionalPreviewBuilderTests: XCTestCase {
    private let sut = TransactionalPreviewBuilder()

    func testBuildPreview_extractsTransactionalTitleAndAmount() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>You paid Andrew Archer</h1>
            <p>$100.00</p>
            <p><a href="https://venmo.com/story/123">See transaction</a></p>
            <h2>Transaction details</h2>
            <p>Date</p>
            <p>Apr 08, 2026</p>
            <p>Status</p>
            <p>Pending</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderName: "Venmo",
            senderEmail: "venmo@venmo.com",
            subject: "You paid Andrew Archer $100.00"
        )

        XCTAssertEqual(result?.title, "You paid Andrew Archer")
        XCTAssertEqual(result?.amount, "$100.00")
        XCTAssertEqual(result?.status, "Pending")
        XCTAssertEqual(result?.actionLabel, "See transaction")
        XCTAssertEqual(result?.detailLine, "Apr 08, 2026")
    }

    func testBuildPreview_ignoresVenmoPromoBannerAndPrefersAvatarImage() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.venmo.com/promos/cashback-banner.png" width="600" height="240" alt="Earn up to 5% cashback banner">
            <p>Earn up to 5% cashback and earn rewards.</p>
            <img src="https://pics-v3.venmo.com/andrew-archer?width=100&height=100" width="93" height="93" alt="Andrew Archer image">
            <h1>You paid Andrew Archer</h1>
            <p>$100.00</p>
            <p>:venmo_dollar:</p>
            <p><a href="https://venmo.com/story/123">See transaction</a></p>
            <h2>Transaction details</h2>
            <p>Date</p>
            <p>Apr 08, 2026</p>
            <p>Status</p>
            <p>Pending</p>
            <p>Payment Method</p>
            <p>Venmo balance</p>
            <p>For security reasons, you cannot unsubscribe from payment emails.</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: nil,
            senderName: "Venmo",
            senderEmail: "venmo@venmo.com",
            subject: "You paid Andrew Archer $100.00"
        )

        XCTAssertEqual(result?.title, "You paid Andrew Archer")
        XCTAssertEqual(result?.imageURL, "https://pics-v3.venmo.com/andrew-archer?width=100&height=100")
        XCTAssertEqual(result?.imageStyle, .avatar)
        XCTAssertEqual(result?.detailLine, "Apr 08, 2026 • Venmo balance")
        XCTAssertNil(result?.subtitle)
    }

    func testBuildPreview_rejectsDuplicateSnippetAndUsesRealSecondaryDetail() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <h1>You paid Andrew Archer</h1>
            <p>$100.00</p>
            <p>For sushi dinner</p>
            <p><a href="https://venmo.com/story/123">See transaction</a></p>
            <h2>Transaction details</h2>
            <p>Date</p>
            <p>Apr 08, 2026</p>
            <p>Status</p>
            <p>Pending</p>
        </body>
        </html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            bodyText: "You paid Andrew Archer $100.00\nFor sushi dinner\nDate\nApr 08, 2026\nStatus\nPending",
            cleanedSnippet: "You paid Andrew Archer $100.00",
            senderName: "Venmo",
            senderEmail: "venmo@venmo.com",
            subject: "Payment complete"
        )

        XCTAssertEqual(result?.title, "You paid Andrew Archer")
        XCTAssertEqual(result?.amount, "$100.00")
        XCTAssertEqual(result?.subtitle, "For sushi dinner")
    }
}
