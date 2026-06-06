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

    func testTheme_previewDisplayPurposeHonorsDarkMode() {
        let light = HTMLDisplayWrapper.theme(isDarkMode: false, displayPurpose: .preview)
        let dark = HTMLDisplayWrapper.theme(isDarkMode: true, displayPurpose: .preview)

        XCTAssertEqual(light.backgroundColorHex, "#f2f2f7")
        XCTAssertEqual(light.textColorHex, "#000000")
        XCTAssertEqual(dark.backgroundColorHex, "#1c1c1e")
        XCTAssertEqual(dark.textColorHex, "#ffffff")
    }

    func testTheme_originalDisplayPurposePreservesLightPresentationInDarkMode() {
        let light = HTMLDisplayWrapper.theme(isDarkMode: false, displayPurpose: .original)
        let dark = HTMLDisplayWrapper.theme(isDarkMode: true, displayPurpose: .original)

        XCTAssertEqual(light, dark)
        XCTAssertEqual(dark.backgroundColorHex, "#ffffff")
        XCTAssertEqual(dark.textColorHex, "#000000")
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

    func testWrapHTMLForDisplay_darkPreviewAppliesFallbackTextCSSOnlyForPreview() {
        let html = """
        <p style="color: #123456;">Authored color survives</p>
        <p>Fallback color can adapt</p>
        """

        let lightPreview = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .preview)
        let darkPreview = sut.wrapHTMLForDisplay(html, isDarkMode: true, displayPurpose: .preview)
        let darkOriginal = sut.wrapHTMLForDisplay(html, isDarkMode: true, displayPurpose: .original)

        XCTAssertTrue(darkPreview.contains(#"p:not([style*="color"])"#))
        XCTAssertTrue(darkPreview.contains("color: #ffffff"))
        XCTAssertTrue(darkPreview.contains("color: #123456;"))
        XCTAssertFalse(lightPreview.contains(#"p:not([style*="color"])"#))
        XCTAssertFalse(darkOriginal.contains(#"p:not([style*="color"])"#))
        XCTAssertTrue(darkOriginal.contains("background-color: #ffffff"))
        XCTAssertFalse(darkOriginal.contains("background-color: #1c1c1e"))
    }

    func testWrapHTMLForDisplay_existingDocument_darkPreviewUsesReadableFallbackStyling() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <p>Unstyled forwarded text</p>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: true, displayPurpose: .preview)

        XCTAssertTrue(result.contains("background-color: #1c1c1e;"))
        XCTAssertTrue(result.contains(#"p:not([style*="color"])"#))
        XCTAssertTrue(result.contains("color: #ffffff;"))
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

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForCSSFixedWidthWithClassAttributeResponsiveSelector() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media screen {
                .container { width: 600px; }
            }
            @media only screen and (max-width: 480px) {
                *[class=container] { width: 100% !important; }
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

    func testWrapHTMLForDisplay_originalPurposeKeepsFixedViewportForCSSFixedWidthExactClassAttributeMismatch() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            .container { width: 600px; }
            @media only screen and (max-width: 480px) {
                *[class=container] { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <div class="container legacy">Legacy marketing layout</div>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeKeepsFixedViewportForComplexFixedSelectorWithUnrelatedResponsiveElement() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            .desktop .container { width: 600px; }
            @media only screen and (max-width: 480px) {
                #mobile { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <div class="desktop">
                <div class="container">Fixed marketing layout</div>
            </div>
            <div id="mobile" class="container">Mobile helper</div>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForComplexFixedSelectorSameElementOverride() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            .desktop .container { width: 600px; }
            @media only screen and (max-width: 480px) {
                #hero { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <div class="desktop">
                <div id="hero" class="container">Responsive marketing layout</div>
            </div>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeKeepsFixedViewportForComplexResponsiveSelectorUnmatchedAncestor() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            .desktop .container { width: 600px; }
            @media only screen and (max-width: 480px) {
                .mobile #hero { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <div class="desktop">
                <div id="hero" class="container">Fixed marketing layout</div>
            </div>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForComplexResponsiveSelectorMatchedAncestor() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            .desktop .container { width: 600px; }
            @media only screen and (max-width: 480px) {
                .desktop #hero { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <div class="desktop">
                <div id="hero" class="container">Responsive marketing layout</div>
            </div>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForAdjacentSiblingResponsiveSelector() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            .container { width: 600px; }
            @media only screen and (max-width: 480px) {
                .intro + .container { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <div class="intro">Intro</div>
            <div class="container">Responsive marketing layout</div>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForGeneralSiblingResponsiveSelector() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            .container { width: 600px; }
            @media only screen and (max-width: 480px) {
                .intro ~ .container { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <div class="intro">Intro</div>
            <p>Spacer</p>
            <div class="container">Responsive marketing layout</div>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeKeepsFixedViewportWhenResponsiveOverrideMissesFixedTarget() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media only screen and (max-width: 480px) {
                .responsive { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <table width="600" class="responsive"><tr><td>Responsive section</td></tr></table>
            <table width="600" class="legacy"><tr><td>Fixed section</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportWhenSplitMediaBlocksCoverFixedTargets() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media only screen and (max-width: 480px) {
                .first { width: 100% !important; }
            }
            @media only screen and (max-width:480px) {
                .second { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <table width="600" class="first"><tr><td>First responsive section</td></tr></table>
            <table width="600" class="second"><tr><td>Second responsive section</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeKeepsFixedViewportWhenSplitMediaBlockOverridesFluidSelector() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media only screen and (max-width: 480px) {
                .first { width: 100% !important; }
            }
            @media only screen and (max-width:480px) {
                .first { width: 600px !important; }
                .second { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <table width="600" class="first"><tr><td>Fixed section</td></tr></table>
            <table width="600" class="second"><tr><td>Responsive section</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeKeepsParentFluidViewportWhenNestedMediaQueryIsInactive() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media (max-width:480px) {
                .container { width:100% !important; }

                @media (min-width:600px) {
                    .container { width:600px !important; }
                }
            }
            </style>
        </head>
        <body>
            <table width="600" class="container"><tr><td>Responsive section</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeIgnoresInactiveNestedFluidOverride() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media (max-width:480px) {
                .container { width:600px !important; }

                @media (min-width:600px) {
                    .container { width:100% !important; }
                }
            }
            </style>
        </head>
        <body>
            <table width="600" class="container"><tr><td>Fixed section</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeAppliesActiveNestedFixedOverride() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media (max-width:480px) {
                .container { width:100% !important; }

                @media (min-width:376px) {
                    .container { width:600px !important; }
                }
            }
            </style>
        </head>
        <body>
            <table width="600" class="container"><tr><td>Fixed section</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeKeepsFixedViewportForNestedFluidSubBreakpoint() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media (max-width:480px) {
                .container { width:600px !important; }

                @media (max-width:400px) {
                    .container { width:100% !important; }
                }
            }
            </style>
        </head>
        <body>
            <table width="600" class="container"><tr><td>Fixed section</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeAppliesUnconditionalNestedScreenMediaOverride() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media (max-width:480px) {
                .container { width:600px !important; }

                @media screen {
                    .container { width:100% !important; }
                }
            }
            </style>
        </head>
        <body>
            <table width="600" class="container"><tr><td>Responsive section</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForDecimalResponsiveBreakpoint() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media (max-width: 575.98px) {
                .container { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <table width="600" class="container"><tr><td>Responsive marketing layout</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForEmResponsiveBreakpoint() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media (max-width: 30em) {
                .container { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <table width="600" class="container"><tr><td>Responsive marketing layout</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForRemResponsiveBreakpoint() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media (max-width: 30rem) {
                .container { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <table width="600" class="container"><tr><td>Responsive marketing layout</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeKeepsFixedViewportForRemBreakpointBelowPhoneRange() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media (max-width: 20rem) {
                .container { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <table width="600" class="container"><tr><td>Fixed marketing layout</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForOversizedResponsiveBreakpoint() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media (max-width: 999999999999999999999px) {
                .container { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <table width="600" class="container"><tr><td>Responsive marketing layout</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeKeepsFixedViewportForMixedFluidAndFixedSelectorsInSameQuery() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media only screen and (max-width: 480px) {
                .first { width: 100% !important; }
                .second { width: 600px !important; }
            }
            </style>
        </head>
        <body>
            <table width="600" class="first"><tr><td>Responsive section</td></tr></table>
            <table width="600" class="second"><tr><td>Fixed section</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeKeepsFixedViewportForUnmatchedSiblingResponsiveSelector() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            .container { width: 600px; }
            @media only screen and (max-width: 480px) {
                .intro + .container { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <div class="intro">Intro</div>
            <p>Spacer</p>
            <div class="container">Fixed marketing layout</div>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
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

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForResponsiveInlineFixedWidth() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media (max-width: 480px) {
                .container { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <div class="container" style="width: 600px;">Responsive marketing layout</div>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForClassAttributeResponsiveSelector() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media only screen and (max-width: 480px) {
                *[class=container] { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <table width="600" class="container"><tr><td>Responsive marketing layout</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=600"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForTestFlightTemplate() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            body {
                margin: 0;
                padding: 0;
            }
            @media only screen and (max-width: 580px) {
                table[class="table"], td[class="cell"] {
                    width: 100% !important;
                }
                body {
                    margin: 0 15px;
                }
            }
            </style>
        </head>
        <body>
            <table class="table" border="0" cellspacing="0" cellpadding="0" align="center" width="580">
                <tr><td class="cell"><h1>Inbox chat 1.0 (129) is ready to test on iOS.</h1></td></tr>
            </table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=580"#))
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
            <table align="center" width="600" role="presentation" class="mj-full-width-mobile">
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

    func testWrapHTMLForDisplay_originalPurposeKeepsFixedViewportForNestedResponsiveHelpers() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            .heroImage { width: 600px; }
            @media only screen and (max-width:480px) {
                .ctaButton { width: 100% !important; }
                .heroImage { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <table align="center" width="600" role="presentation" class="legacyShell">
                <tr>
                    <td>
                        <img class="heroImage" src="https://example.com/hero.jpg" width="600" style="width: 600px;">
                        <a class="ctaButton" href="https://example.com" style="width: 600px;">Open</a>
                    </td>
                </tr>
            </table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeKeepsFixedViewportForExactClassAttributeSelectorMismatch() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            @media only screen and (max-width: 480px) {
                *[class=container] { width: 100% !important; }
            }
            </style>
        </head>
        <body>
            <table width="600" class="container legacy"><tr><td>Legacy marketing layout</td></tr></table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=600, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
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

    func testWrapHTMLForDisplay_originalPurposeUsesFixedViewportForTableMaxWidthNewsletterLayout() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            table.outer-wrap {
                max-width: 568px;
                width: 100%;
            }
            @media only screen and (max-width: 480px) {
                .cardcol {
                    display: block !important;
                    width: 100% !important;
                }
            }
            </style>
        </head>
        <body>
            <table class="outer-wrap" align="center" role="presentation">
                <tr>
                    <td class="story" width="50%">Image column</td>
                    <td class="story" width="50%">Text column</td>
                </tr>
            </table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=568, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesFixedViewportForExplicitTableMaxWidthWithFluidWidthAttribute() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            table.outer-wrap {
                max-width: 568px;
            }
            </style>
        </head>
        <body>
            <table class="outer-wrap" width="100%" align="center" role="presentation">
                <tr>
                    <td>Desktop newsletter layout</td>
                </tr>
            </table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=568, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesFixedViewportForClassOnlyTableMaxWidthLayout() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            .outer-wrap {
                max-width: 568px;
                width: 100%;
            }
            @media only screen and (max-width: 480px) {
                .cardcol {
                    display: block !important;
                    width: 100% !important;
                }
            }
            </style>
        </head>
        <body>
            <table class="outer-wrap" align="center" role="presentation">
                <tr>
                    <td class="story" width="50%">Image column</td>
                    <td class="story" width="50%">Text column</td>
                </tr>
            </table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=568, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesFixedViewportForIDOnlyTableMaxWidthLayout() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            #outer-wrap {
                max-width: 568px;
                width: 100%;
            }
            @media only screen and (max-width: 480px) {
                .cardcol {
                    display: block !important;
                    width: 100% !important;
                }
            }
            </style>
        </head>
        <body>
            <table id="outer-wrap" align="center" role="presentation">
                <tr>
                    <td class="story" width="50%">Image column</td>
                    <td class="story" width="50%">Text column</td>
                </tr>
            </table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=568, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=device-width"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForResponsiveClassOnlyTableMaxWidthLayout() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            .outer-wrap {
                max-width: 568px;
                width: 100%;
            }
            @media only screen and (max-width: 480px) {
                .outer-wrap {
                    width: 100% !important;
                }
            }
            </style>
        </head>
        <body>
            <table class="outer-wrap" align="center" role="presentation">
                <tr><td>Responsive newsletter layout</td></tr>
            </table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=568"#))
    }

    func testWrapHTMLForDisplay_originalPurposeUsesDeviceViewportForResponsiveTableMaxWidthLayout() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
            table.outer-wrap {
                max-width: 568px;
                width: 100%;
            }
            @media only screen and (max-width: 480px) {
                .outer-wrap {
                    width: 100% !important;
                }
            }
            </style>
        </head>
        <body>
            <table class="outer-wrap" align="center" role="presentation">
                <tr><td>Responsive newsletter layout</td></tr>
            </table>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(html, isDarkMode: false, displayPurpose: .original)

        XCTAssertTrue(result.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#))
        XCTAssertFalse(result.contains(#"<meta name="viewport" content="width=568"#))
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

    func testWrapHTMLForDisplay_stringOnlySerialization_preservesAuthorMarkupAndInjectsHardenedCSP() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>.hero { width: 600px; }</style>
        </head>
        <body>
            <img src="https://cdn.example.com/hero.jpg" alt="Hero">
            <p>Reader body</p>
        </body>
        </html>
        """

        let result = sut.wrapHTMLForDisplay(
            html,
            isDarkMode: false,
            displayPurpose: .original,
            headSerialization: .stringOnly
        )

        XCTAssertTrue(result.contains("Reader body"))
        XCTAssertTrue(result.contains("https://cdn.example.com/hero.jpg"))
        // Author markup is spliced, not re-serialized, so original style rules survive verbatim.
        XCTAssertTrue(result.contains(".hero { width: 600px; }"))
        // The injected head still applies the hardened CSP and light original surface.
        XCTAssertTrue(result.contains("script-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none';"))
        XCTAssertTrue(result.contains("background-color: #ffffff"))
    }

    func testWrapHTMLForDisplay_stringOnlySerialization_fragmentFallsBackToPartialTemplate() {
        // A bare fragment (no <html>/<head>) still receives the full template + hardened CSP.
        let html = "<div>Fragment body</div>"

        let result = sut.wrapHTMLForDisplay(
            html,
            isDarkMode: false,
            displayPurpose: .original,
            headSerialization: .stringOnly
        )

        XCTAssertTrue(result.contains("Fragment body"))
        XCTAssertTrue(result.contains("form-action 'none'; base-uri 'none'"))
    }
}
