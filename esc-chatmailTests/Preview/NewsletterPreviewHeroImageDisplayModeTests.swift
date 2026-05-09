import CoreGraphics
import XCTest
@testable import esc_chatmail

final class NewsletterPreviewHeroImageDisplayModeTests: XCTestCase {
    func testResolved_keepsExplicitFitPreference() {
        let mode = NewsletterPreviewHeroImageDisplayMode.resolved(
            preferred: .fit,
            imageSize: CGSize(width: 640, height: 320)
        )

        XCTAssertEqual(mode, .fit)
    }

    func testResolved_promotesVeryWideImagesToFitWhenPreferredModeIsFill() {
        let mode = NewsletterPreviewHeroImageDisplayMode.resolved(
            preferred: .fill,
            imageSize: CGSize(width: 665, height: 142)
        )

        XCTAssertEqual(mode, .fit)
    }

    func testResolved_keepsStandardHeroImagesAsFill() {
        let mode = NewsletterPreviewHeroImageDisplayMode.resolved(
            preferred: .fill,
            imageSize: CGSize(width: 640, height: 320)
        )

        XCTAssertEqual(mode, .fill)
    }

    func testResolved_keepsModeratelyWideImagesAsFill() {
        let mode = NewsletterPreviewHeroImageDisplayMode.resolved(
            preferred: .fill,
            imageSize: CGSize(width: 612, height: 240)
        )

        XCTAssertEqual(mode, .fill)
    }

    func testResolved_preservesPreferenceForInvalidImageSize() {
        let mode = NewsletterPreviewHeroImageDisplayMode.resolved(
            preferred: .fill,
            imageSize: CGSize(width: 1260, height: 0)
        )

        XCTAssertEqual(mode, .fill)
    }
}
