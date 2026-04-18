import XCTest
@testable import esc_chatmail

final class HTMLDisplayWrapperTests: XCTestCase {
    private let appleMailFallbackFontStack = "font-family: -apple-system, BlinkMacSystemFont, \"Helvetica Neue\", Helvetica, Arial, sans-serif;"
    private var sut: HTMLDisplayWrapper!

    override func setUp() {
        super.setUp()
        sut = HTMLDisplayWrapper()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    func testWrapHTMLForDisplay_partialHTML_originalUsesAppleMailFallbackTypography() {
        let html = """
        <div>Hello from Apple Mail</div>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(appleMailFallbackFontStack))
        XCTAssertTrue(result.contains("background-color: #ffffff"))
        XCTAssertTrue(result.contains("word-wrap: break-word"))
    }

    func testWrapHTMLForDisplay_partialHTML_previewUsesPreviewSurfaceForLightAndDarkModes() {
        let html = "<div>Hello from preview</div>"

        let lightResult = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .preview)
        let darkResult = sut.wrapHTMLForDisplay(html, isDarkMode: true, displayPurpose: .preview)

        XCTAssertTrue(lightResult.contains("background-color: #f2f2f7"))
        XCTAssertTrue(darkResult.contains("background-color: #1c1c1e"))
        XCTAssertTrue(darkResult.contains("color: #ffffff"))
        XCTAssertFalse(lightResult.contains(appleMailFallbackFontStack))
    }

    func testWrapHTMLForDisplay_existingDocumentWithoutFontStyling_usesAppleMailFallbackTypography() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <p>Hello</p>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(appleMailFallbackFontStack))
        XCTAssertEqual(result.components(separatedBy: appleMailFallbackFontStack).count - 1, 1)
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
        XCTAssertFalse(result.contains(appleMailFallbackFontStack))
    }

    func testWrapHTMLForDisplay_existingDocumentWithInlineDocumentFont_keepsAuthorTypography() {
        let html = """
        <!DOCTYPE html>
        <html style="font: 16px Georgia, serif;">
        <body>
            <p>Hello</p>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains("font: 16px Georgia, serif;"))
        XCTAssertFalse(result.contains(appleMailFallbackFontStack))
    }

    func testWrapHTMLForDisplay_existingDocument_usesDarkPreviewSurfaceButLightOriginalSurface() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <p>Hello</p>
        </body>
        </html>
        """

        let preview = sut.wrapHTMLForDisplay(html, isDarkMode: true, displayPurpose: .preview)
        let original = sut.wrapHTMLForDisplay(html, isDarkMode: true, displayPurpose: .original)

        XCTAssertTrue(preview.contains("background-color: #1c1c1e;"))
        XCTAssertTrue(original.contains("background-color: #ffffff;"))
        XCTAssertFalse(original.contains("background-color: #000000;"))
        XCTAssertTrue(original.contains("<meta name=\"color-scheme\" content=\"light\">"))
        XCTAssertTrue(original.contains("color-scheme: light;"))
    }

    func testWrapHTMLForDisplay_existingDocument_originalDarkModeDoesNotInjectPreviewTextOverrides() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <p style="color: rgb(54,55,55);">Authored text color</p>
            <p>Unstyled text</p>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: true, displayPurpose: .original)

        XCTAssertFalse(result.contains("p:not([style*=\"color\"])"))
        XCTAssertFalse(result.contains("li:not([style*=\"color\"])"))
        XCTAssertTrue(result.contains("color: rgb(54,55,55);"))
    }

    func testWrapHTMLForDisplay_originalPurpose_preservesDefaultLinkStyling() {
        let html = """
        <p><a href="https://example.com/file.pdf">Open file</a></p>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertFalse(result.contains("text-decoration: inherit"))
        XCTAssertFalse(result.contains("color: inherit"))
        XCTAssertTrue(result.contains("https://example.com/file.pdf"))
    }

    func testWrapHTMLForDisplay_equivalentFragmentAndDocumentInputs_shareFallbackTypographyBehavior() {
        let fragmentHTML = "<div>Hello</div>"
        let documentHTML = """
        <!DOCTYPE html>
        <html>
        <body><div>Hello</div></body>
        </html>
        """

        let fragmentResult = sut.wrapHTMLForDisplay(fragmentHTML, isDarkMode: false, displayPurpose: .original)
        let documentResult = sut.wrapHTMLForDisplay(documentHTML, isDarkMode: false, displayPurpose: .original)

        XCTAssertEqual(fragmentResult.components(separatedBy: appleMailFallbackFontStack).count - 1, 1)
        XCTAssertEqual(documentResult.components(separatedBy: appleMailFallbackFontStack).count - 1, 1)
    }
}
