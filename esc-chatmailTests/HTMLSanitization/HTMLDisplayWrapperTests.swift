import XCTest
@testable import esc_chatmail

final class HTMLDisplayWrapperTests: XCTestCase {
    private var sut: HTMLDisplayWrapper!

    override func setUp() {
        super.setUp()
        sut = HTMLDisplayWrapper()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    func testWrapHTMLForDisplay_partialHTML_doesNotInjectFallbackTypography() {
        let html = """
        <div>Hello from Apple Mail</div>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false)

        XCTAssertFalse(result.contains("font-family: -apple-system"))
        XCTAssertFalse(result.contains("font-size: 16px"))
        XCTAssertFalse(result.contains("line-height: 1.5"))
        XCTAssertTrue(result.contains("background-color: #ffffff"))
        XCTAssertTrue(result.contains("word-wrap: break-word"))
    }

    func testWrapHTMLForDisplay_existingDocument_keepsAuthorBodyStyles() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                body { font-family: Georgia, serif; font-size: 19px; }
            </style>
        </head>
        <body>
            <p>Hello</p>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false)

        XCTAssertTrue(result.contains("body { font-family: Georgia, serif; font-size: 19px; }"))
        XCTAssertFalse(result.contains("font-family: -apple-system"))
    }
}
