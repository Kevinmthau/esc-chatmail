import XCTest
@testable import esc_chatmail

final class EmailContentSectionOpenPolicyTests: XCTestCase {
    func testNewsletterPreviewPreparesFullEmailBeforeOpening() {
        let model = NewsletterPreviewModel(
            title: "Sale",
            subtitle: nil,
            snippet: "Open the full email.",
            heroImageURL: nil,
            heroImageDisplayMode: .fill,
            sourceLabel: "Store",
            sourceDomain: "store.example"
        )

        XCTAssertTrue(
            EmailContentSection.shouldPrepareFullEmailBeforeOpening(.newsletter(model))
        )
    }

    func testHTMLPreviewOpensWithoutPreparationGate() {
        let payload = HTMLPreviewPayload(
            html: "<html><body>Message</body></html>",
            previewCacheKey: "preview-cache-key"
        )

        XCTAssertFalse(
            EmailContentSection.shouldPrepareFullEmailBeforeOpening(.html(payload))
        )
    }
}
