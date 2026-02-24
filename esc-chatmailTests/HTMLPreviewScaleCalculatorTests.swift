import XCTest
@testable import esc_chatmail

final class HTMLPreviewScaleCalculatorTests: XCTestCase {
    func testEstimatedLayoutWidth_prefersLargestMinWidth() {
        let html = """
        <style>
            .wrp { min-width:640px; }
            .content { width:576px; }
        </style>
        <table class="wrp" width="576"></table>
        """

        let width = HTMLPreviewScaleCalculator.estimatedLayoutWidth(from: html)

        XCTAssertEqual(width, 640)
    }

    func testEstimatedLayoutWidth_readsQuotedPrintableWidthAttribute() {
        let html = """
        <table width=3D"640"><tr><td>Hello</td></tr></table>
        """

        let width = HTMLPreviewScaleCalculator.estimatedLayoutWidth(from: html)

        XCTAssertEqual(width, 640)
    }

    func testEstimatedLayoutWidth_handlesQuotedPrintableSoftBreaks() {
        let html = """
        <style>
            .wrp { min-w=
        idth:640px; }
        </style>
        <table width=3D"576"></table>
        """

        let width = HTMLPreviewScaleCalculator.estimatedLayoutWidth(from: html)

        XCTAssertEqual(width, 640)
    }

    func testPreviewScale_reducesWhenContentWouldOverflowBubble() {
        let html = """
        <style>.wrp { min-width:640px; }</style>
        <table class="wrp"></table>
        """

        let scale = HTMLPreviewScaleCalculator.previewScale(
            defaultScale: 0.5,
            containerWidth: 280,
            html: html
        )

        XCTAssertEqual(scale, 280.0 / (640.0 + 24.0), accuracy: 0.0001)
    }

    func testPreviewScale_keepsDefaultWhenContentFits() {
        let html = """
        <style>.wrp { min-width:320px; }</style>
        <table class="wrp"></table>
        """

        let scale = HTMLPreviewScaleCalculator.previewScale(
            defaultScale: 0.5,
            containerWidth: 280,
            html: html
        )

        XCTAssertEqual(scale, 0.5, accuracy: 0.0001)
    }
}
