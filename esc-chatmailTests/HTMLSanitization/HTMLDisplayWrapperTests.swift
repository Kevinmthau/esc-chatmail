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

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains("body { font-family: Georgia, serif; font-size: 19px; }"))
        XCTAssertFalse(result.contains(appleMailFallbackFontStack))
    }

    func testWrapHTMLForDisplay_existingDocumentWithMultilineBodyStyle_keepsAuthorTypography() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body
            style="
                color: #222222;
                font-family: Georgia, serif;
            "
        >
            <p>Hello</p>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains("font-family: Georgia, serif;"))
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

    func testWrapHTMLForDisplay_existingDocumentWithMultilineHTMLStyleFontShorthand_keepsAuthorTypography() {
        let html = """
        <!DOCTYPE html>
        <html
            style="
                color: #111111;
                font: italic 17px Georgia, serif;
            "
        >
        <body>
            <p>Hello</p>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains("font: italic 17px Georgia, serif;"))
        XCTAssertFalse(result.contains(appleMailFallbackFontStack))
    }

    func testWrapHTMLForDisplay_existingDocumentWithOnlyRootCustomProperties_usesAppleMailFallbackTypography() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                :root {
                    --body-font: Georgia, serif;
                    --font-family: "Avenir Next", sans-serif;
                }
            </style>
        </head>
        <body>
            <p>Hello</p>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(appleMailFallbackFontStack))
        XCTAssertEqual(result.components(separatedBy: appleMailFallbackFontStack).count - 1, 1)
    }

    func testWrapHTMLForDisplay_existingDocumentWithRootStylesheetFontRule_keepsAuthorTypography() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                html,
                body {
                    color: #111111;
                    font-family: Georgia, serif;
                }
            </style>
        </head>
        <body>
            <p>Hello</p>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains("font-family: Georgia, serif;"))
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

    func testWrapHTMLForDisplay_originalPurposeUsesFixedViewportForLegacyLayout() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <table width="600"><tr><td>Legacy marketing layout</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains("shrink-to-fit=no"))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesFixedViewportForUnconditionalScreenMediaWidth() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media screen {
                .container { width: 600px; }
            }
            </style>
        </head>
        <body>
            <div class="container">Fixed marketing layout</div>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains("shrink-to-fit=no"))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForResponsiveScreenMediaWidth() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media screen {
                .container { width: 600px; }
            }
            @media screen and (max-width: 480px) {
                .container { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <div class="container">Responsive marketing layout</div>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForResponsiveWidthWithoutMediaType() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media screen {
                .container { width: 600px; }
            }
            @media (max-width: 480px) {
                .container { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <div class="container">Responsive marketing layout</div>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForResponsiveFixedWidthTables() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media only screen and (max-width:479px) {
                table.mj-full-width-mobile { width: 100% !important; }
                td.mj-full-width-mobile { width: auto !important; }
            }
            </style>
        </head>
        <body>
            <table align="center" width="600" role="presentation">
                <tr>
                    <td style="width:600px;" class="mj-full-width-mobile">
                        <img src="https://example.com/hero.jpg" width="600">
                    </td>
                </tr>
            </table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportWithoutFixedLayout() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <p>Fluid message</p>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains("shrink-to-fit=no"))
    }

    func testWrapHTMLForDisplay_originalPurposeIgnoresResponsiveMaxWidthBreakpoints() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            .container { max-width: 600px; width: 100%; margin: 0 auto; }
            @media only screen and (max-width: 600px) {
                .container { width: 100% !important; }
            }
            @media only screen and (min-width: 600px) {
                .container { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <div class="container">Fluid message</div>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeIgnoresOutlookAndDesktopOnlyWidths() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            .templateContainer {
                max-width: 600px !important;
            }
            @media only screen and (min-width:768px) {
                .templateContainer {
                    width: 600px !important;
                }
            }
            @media only screen and (max-width:480px) {
                .mcnImage {
                    width: 100% !important;
                }
            }
            </style>
        </head>
        <body>
            <!--[if (gte mso 9)|(IE)]>
            <table align="center" border="0" cellspacing="0" cellpadding="0" width="600">
            <tr><td width="600">
            <![endif]-->
            <table class="templateContainer" width="100%">
                <tr>
                    <td><img class="mcnImage" src="https://example.com/hero.jpg" width="564"></td>
                </tr>
            </table>
            <!--[if (gte mso 9)|(IE)]>
            </td></tr></table>
            <![endif]-->
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesFixedViewportForSevenRoomsBreakpointTemplate() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media all and (min-width:376px) {
                .email-bg-size { width: 600px !important; }
                .card-size { width: 480px !important; }
            }
            @media all and (max-width:375px) {
                .email-bg-size { width: 375px !important; }
                .card-size { width: 355px !important; }
            }
            </style>
        </head>
        <body>
            <table width="600" class="email-bg-size">
                <tr><td><table class="card-size" style="width: 480px;"><tr><td>Reservation</td></tr></table></td></tr>
            </table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains("shrink-to-fit=no"))
    }

    func testWrapHTMLForDisplay_previewPurposeKeepsShrinkToFitDisabled() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <table width="600"><tr><td>Preview layout</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .preview)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, shrink-to-fit=no, user-scalable=yes">"#))
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

    func testWrapHTMLForDisplay_equivalentFragmentAndDocumentInputsWithAuthoredRootTypography_shareBehavior() {
        let fragmentHTML = """
        <style>
            body {
                font-family: Georgia, serif;
            }
        </style>
        <div>Hello</div>
        """
        let documentHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                body {
                    font-family: Georgia, serif;
                }
            </style>
        </head>
        <body><div>Hello</div></body>
        </html>
        """

        let fragmentResult = sut.wrapHTMLForDisplay(fragmentHTML, isDarkMode: false, displayPurpose: .original)
        let documentResult = sut.wrapHTMLForDisplay(documentHTML, isDarkMode: false, displayPurpose: .original)

        XCTAssertFalse(fragmentResult.contains(appleMailFallbackFontStack))
        XCTAssertFalse(documentResult.contains(appleMailFallbackFontStack))
    }
}
