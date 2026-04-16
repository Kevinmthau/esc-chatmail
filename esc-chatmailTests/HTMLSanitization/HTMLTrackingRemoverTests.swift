import XCTest
@testable import esc_chatmail

final class HTMLTrackingRemoverTests: XCTestCase {

    private var sut: HTMLTrackingRemover!

    override func setUp() {
        super.setUp()
        sut = HTMLTrackingRemover()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - removeTrackingPixels: 1x1 images

    func testRemoveTrackingPixels_widthHeight1_removed() {
        let html = "<p>before</p><img src=\"https://x.com/p.gif\" width=\"1\" height=\"1\"><p>after</p>"
        let result = sut.removeTrackingPixels(html)
        XCTAssertFalse(result.contains("<img"))
        XCTAssertTrue(result.contains("<p>before</p>"))
        XCTAssertTrue(result.contains("<p>after</p>"))
    }

    func testRemoveTrackingPixels_heightFirst1x1_removed() {
        let html = "<img src=\"https://x.com/p.gif\" height=\"1\" width=\"1\">"
        let result = sut.removeTrackingPixels(html)
        XCTAssertFalse(result.contains("<img"))
    }

    func testRemoveTrackingPixels_cssSized1x1_removed() {
        let html = "<img src=\"https://x.com/p.gif\" style=\"width:1px;height:1px\">"
        let result = sut.removeTrackingPixels(html)
        XCTAssertFalse(result.contains("<img"))
    }

    func testRemoveTrackingPixels_cssHeightFirst_removed() {
        let html = "<img src=\"https://x.com/p.gif\" style=\"height: 1px; width: 1px\">"
        let result = sut.removeTrackingPixels(html)
        XCTAssertFalse(result.contains("<img"))
    }

    func testRemoveTrackingPixels_normalSizedImage_preserved() {
        let html = "<img src=\"https://x.com/hero.jpg\" width=\"600\" height=\"400\">"
        let result = sut.removeTrackingPixels(html)
        XCTAssertTrue(result.contains("<img"))
        XCTAssertTrue(result.contains("hero.jpg"))
    }

    // MARK: - removeTrackingPixels: known tracking domains

    func testRemoveTrackingPixels_doubleclickImage_removed() {
        let html = "<img src=\"https://doubleclick.net/pixel?id=1\">"
        let result = sut.removeTrackingPixels(html)
        XCTAssertFalse(result.contains("doubleclick.net"))
    }

    func testRemoveTrackingPixels_googleAnalyticsImage_removed() {
        let html = "<img src=\"https://www.google-analytics.com/collect?v=1\">"
        let result = sut.removeTrackingPixels(html)
        XCTAssertFalse(result.contains("google-analytics.com"))
    }

    func testRemoveTrackingPixels_bingUETImage_removed() {
        let html = "<img src=\"https://bat.bing.com/action/0?ti=123\">"
        let result = sut.removeTrackingPixels(html)
        XCTAssertFalse(result.contains("bat.bing.com"))
    }

    // MARK: - removeTrackingPixels: tracking subdomains

    func testRemoveTrackingPixels_analyticsSubdomain_removed() {
        let html = "<img src=\"https://analytics.example.com/track\">"
        let result = sut.removeTrackingPixels(html)
        XCTAssertFalse(result.contains("<img"))
    }

    func testRemoveTrackingPixels_pixelSubdomain_removed() {
        let html = "<img src=\"https://pixel.example.com/p.gif\">"
        let result = sut.removeTrackingPixels(html)
        XCTAssertFalse(result.contains("<img"))
    }

    func testRemoveTrackingPixels_beaconSubdomain_removed() {
        let html = "<img src=\"https://beacon.example.com/log\">"
        let result = sut.removeTrackingPixels(html)
        XCTAssertFalse(result.contains("<img"))
    }

    // MARK: - removeTrackingPixels: tracking filenames

    func testRemoveTrackingPixels_spacerGif_removed() {
        let html = "<img src=\"https://safe.com/images/spacer.gif\">"
        let result = sut.removeTrackingPixels(html)
        XCTAssertFalse(result.contains("<img"))
    }

    func testRemoveTrackingPixels_pixelGif_removed() {
        let html = "<img src=\"https://safe.com/path/pixel.gif\">"
        let result = sut.removeTrackingPixels(html)
        XCTAssertFalse(result.contains("<img"))
    }

    func testRemoveTrackingPixels_transparentGif_removed() {
        let html = "<img src=\"https://safe.com/transparent.gif\">"
        let result = sut.removeTrackingPixels(html)
        XCTAssertFalse(result.contains("<img"))
    }

    // MARK: - removeTrackingPixels: mixed content

    func testRemoveTrackingPixels_preservesNormalImagesAlongsideTrackers() {
        let html = """
        <img src="https://cdn.example.com/hero.jpg" width="600" height="400">
        <img src="https://analytics.example.com/pixel" width="1" height="1">
        <img src="https://doubleclick.net/p">
        <img src="https://cdn.example.com/footer.png">
        """
        let result = sut.removeTrackingPixels(html)
        XCTAssertTrue(result.contains("hero.jpg"))
        XCTAssertTrue(result.contains("footer.png"))
        XCTAssertFalse(result.contains("analytics.example.com"))
        XCTAssertFalse(result.contains("doubleclick.net"))
    }

    // MARK: - isTrackingLikeImageURL

    func testIsTrackingLikeImageURL_emptyString_returnsTrue() {
        XCTAssertTrue(sut.isTrackingLikeImageURL(""))
        XCTAssertTrue(sut.isTrackingLikeImageURL("   "))
    }

    func testIsTrackingLikeImageURL_knownTrackingDomainAsHost_returnsTrue() {
        XCTAssertTrue(sut.isTrackingLikeImageURL("https://doubleclick.net/p"))
        XCTAssertTrue(sut.isTrackingLikeImageURL("https://sub.doubleclick.net/p"))
        XCTAssertTrue(sut.isTrackingLikeImageURL("https://www.google-analytics.com/collect"))
    }

    func testIsTrackingLikeImageURL_trackingSubdomainPrefix_returnsTrue() {
        XCTAssertTrue(sut.isTrackingLikeImageURL("https://analytics.example.com/p"))
        XCTAssertTrue(sut.isTrackingLikeImageURL("https://tracking.example.com/p"))
        XCTAssertTrue(sut.isTrackingLikeImageURL("https://pixel.example.com/p"))
    }

    func testIsTrackingLikeImageURL_trackingFilename_returnsTrue() {
        XCTAssertTrue(sut.isTrackingLikeImageURL("https://safe.com/a/b/spacer.gif"))
        XCTAssertTrue(sut.isTrackingLikeImageURL("https://safe.com/open.gif"))
    }

    func testIsTrackingLikeImageURL_ordinaryImage_returnsFalse() {
        XCTAssertFalse(sut.isTrackingLikeImageURL("https://cdn.example.com/hero.jpg"))
        XCTAssertFalse(sut.isTrackingLikeImageURL("https://example.com/logo.png"))
    }

    func testIsTrackingLikeImageURL_caseInsensitive() {
        XCTAssertTrue(sut.isTrackingLikeImageURL("HTTPS://DOUBLECLICK.NET/pixel"))
        XCTAssertTrue(sut.isTrackingLikeImageURL("HTTPS://ANALYTICS.example.com/p"))
    }
}
