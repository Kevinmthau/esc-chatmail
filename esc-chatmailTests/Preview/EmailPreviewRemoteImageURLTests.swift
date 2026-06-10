import XCTest
@testable import esc_chatmail

final class EmailPreviewRemoteImageURLTests: XCTestCase {
    func testAutoLoadableNativePreviewURL_allowsHTTPS() {
        XCTAssertEqual(
            EmailPreviewRemoteImageURL.autoLoadableNativePreviewURL("https://cdn.example.com/hero.jpg"),
            "https://cdn.example.com/hero.jpg"
        )
    }

    func testAutoLoadableNativePreviewURL_upgradesHTTPToHTTPS() {
        XCTAssertEqual(
            EmailPreviewRemoteImageURL.autoLoadableNativePreviewURL("http://cdn.example.com/hero.jpg"),
            "https://cdn.example.com/hero.jpg"
        )
    }

    func testAutoLoadableNativePreviewURL_rejectsNonWebSchemes() {
        XCTAssertNil(EmailPreviewRemoteImageURL.autoLoadableNativePreviewURL("data:image/png;base64,AAAA"))
        XCTAssertNil(EmailPreviewRemoteImageURL.autoLoadableNativePreviewURL("cid:inline-image"))
        XCTAssertNil(EmailPreviewRemoteImageURL.autoLoadableNativePreviewURL("file:///etc/passwd"))
        XCTAssertNil(EmailPreviewRemoteImageURL.autoLoadableNativePreviewURL("javascript:alert(1)"))
    }

    func testAutoLoadableNativePreviewURL_rejectsHostlessOrUnparseableURLs() {
        XCTAssertNil(EmailPreviewRemoteImageURL.autoLoadableNativePreviewURL("https://"))
        XCTAssertNil(EmailPreviewRemoteImageURL.autoLoadableNativePreviewURL("//cdn.example.com/hero.jpg"))
        XCTAssertNil(EmailPreviewRemoteImageURL.autoLoadableNativePreviewURL("not a url"))
        XCTAssertNil(EmailPreviewRemoteImageURL.autoLoadableNativePreviewURL(""))
    }
}
