import SwiftUI
import UIKit
import XCTest
@testable import esc_chatmail

/// A transparent attachment image draws on whatever the transcript's background is, so a black
/// logo on dark mode's black was a 280pt box with its image loaded and nothing visible in it.
@MainActor
final class ImageBackdropPolicyTests: XCTestCase {
    // MARK: - Decision

    func testResolve_darkLogoOnTransparentCanvas_choosesLightBackdrop() throws {
        XCTAssertEqual(try backdrop(logo: .black, canvas: 1_000), .light)
    }

    func testResolve_whiteLogoOnTransparentCanvas_choosesDarkBackdrop() throws {
        XCTAssertEqual(try backdrop(logo: .white, canvas: 1_000), .dark)
    }

    func testResolve_tinyLogoOnLargeCanvas_stillFindsTheContent() throws {
        let image = try decodedPNG(canvas: 1_600) { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 790, y: 790, width: 20, height: 20))
        }
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .light)
    }

    func testResolve_mostlyDarkContentWithALightDetail_followsTheMajority() throws {
        let image = try decodedPNG(canvas: 200) { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 40, y: 40, width: 120, height: 60))
            UIColor.white.setFill()
            context.fill(CGRect(x: 40, y: 110, width: 120, height: 10))
        }
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .light)
    }

    /// Mid-tone content was already visible on both backgrounds, so it keeps floating.
    /// Revert-check: with a single luma threshold in `ImageBackdropPolicy.resolve(for:)`, these
    /// gain a card.
    func testResolve_midToneContentOnTransparentCanvas_leavesTheBackgroundAlone() throws {
        for gray: CGFloat in [0.35, 0.45, 0.6] {
            XCTAssertEqual(try backdrop(logo: UIColor(white: gray, alpha: 1), canvas: 500), .none)
        }
    }

    /// A round headshot: 21% transparent corners around a mid-tone photo.
    /// Revert-check: with a single luma threshold in `ImageBackdropPolicy.resolve(for:)`, this
    /// sits on a white square.
    func testResolve_circularMidTonePhoto_leavesTheBackgroundAlone() throws {
        let image = try decodedPNG(canvas: 300) { _ in
            UIColor(white: 0.45, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 300, height: 300)).fill()
        }
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .none)
    }

    func testResolve_navyLogoOnTransparentCanvas_choosesLightBackdrop() throws {
        let navy = UIColor(red: 0, green: 0x1F / 255, blue: 0x5B / 255, alpha: 1)
        XCTAssertEqual(try backdrop(logo: navy, canvas: 500), .light)
    }

    func testResolve_paleYellowLogoOnTransparentCanvas_choosesDarkBackdrop() throws {
        let yellow = UIColor(red: 1, green: 0xE0 / 255, blue: 0x40 / 255, alpha: 1)
        XCTAssertEqual(try backdrop(logo: yellow, canvas: 500), .dark)
    }

    /// The image the empty box could equally have held. `.light` would turn a black box into a
    /// white one, with nothing to see in either.
    /// Revert-check: without `ImageBackdropPolicy.resolve(for:)`'s `hasVisibleSample` guard this
    /// divides by a zero alpha sum and falls through to `.none`, leaving the box empty.
    func testResolve_fullyTransparentImage_reportsNothingVisible() throws {
        let image = try decodedPNG(canvas: 500) { _ in }
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .nothingVisible)
    }

    func testResolve_opaqueImageInAnAlphaCapableFormat_leavesTheBackgroundAlone() throws {
        let image = try decodedPNG(canvas: 300) { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        XCTAssertTrue(image.alphaInfo.hasAlphaChannel)
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .none)
    }

    /// Revert-check: without `minimumTransparentShare` this dark photo gains a white card that
    /// shows in its corners.
    func testResolve_darkPhotoWithRoundedCorners_leavesTheBackgroundAlone() throws {
        let image = try decodedPNG(canvas: 280) { _ in
            UIColor.black.setFill()
            UIBezierPath(
                roundedRect: CGRect(x: 0, y: 0, width: 280, height: 280),
                cornerRadius: 50
            ).fill()
        }
        XCTAssertTrue(image.alphaInfo.hasAlphaChannel)
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .none)
    }

    func testResolve_jpeg_answersWithoutReadingPixels() throws {
        let data = try XCTUnwrap(
            UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: oneScaleFormat())
                .jpegData(withCompressionQuality: 0.9) { context in
                    UIColor.black.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
                }
        )
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertFalse(image.alphaInfo.hasAlphaChannel)
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .none)
    }

    /// Palette transparency (PLTE + tRNS) is how small logos are commonly saved, and it holds no
    /// alpha channel in the file: the early out must not read it as opaque. A black 4x2 bar on a
    /// fully transparent 8x8 canvas, built by hand because UIKit cannot encode an indexed PNG.
    /// HONEST SCOPE: survives any revert of ours; it pins the assumption `mayHaveTransparency`
    /// makes about how ImageIO reports palette transparency through `CGImage.alphaInfo`.
    func testResolve_indexedPNGWithPaletteTransparency_choosesLightBackdrop() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.indexedLogoPNGBase64))
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .light)
    }

    // MARK: - The thumbnail this policy never sees

    /// Pins the claim the policy's header makes, and the reason an oversized logo was never part
    /// of this bug: its thumbnail is a JPEG, flattened onto white rather than black.
    /// HONEST SCOPE: this pins `UIGraphicsImageRenderer`'s flattening as much as our code.
    func testGenerateThumbnail_oversizedTransparentImage_flattensOntoWhite() throws {
        let oversized = try png(canvas: 2_000) { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 500, y: 800, width: 1_000, height: 400))
        }
        let thumbnail = try XCTUnwrap(
            ImageProcessor.generateThumbnail(from: oversized, mimeType: "image/png")
        )
        let image = try XCTUnwrap(UIImage(data: thumbnail)?.cgImage)

        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .none)
        let bitmap = try rgbaBitmap(of: image)
        XCTAssertEqual(bitmap.color(x: 5, y: 5), [255, 255, 255])
        XCTAssertEqual(bitmap.color(x: bitmap.width / 2, y: bitmap.height / 2), [0, 0, 0])
    }

    func testGenerateThumbnail_transparentImageWithinTheLimit_keepsItsTransparency() throws {
        let original = try png(canvas: 1_000) { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 250, y: 400, width: 500, height: 200))
        }
        XCTAssertEqual(
            ImageProcessor.generateThumbnail(from: original, mimeType: "image/png"),
            original
        )
    }

    // MARK: - Rendering on the dark transcript

    /// The reported bug, end to end: 280pt of nothing but black before, the logo on a light card
    /// now. Revert-check: without the matte branch in `ImageAttachmentBubbleContent`'s
    /// `backgroundColor` every pixel here renders black and the white assertion fails.
    func testRenderedContent_darkLogoOnDarkTranscript_showsTheLogoOnALightCard() throws {
        let image = try UIImage(data: png(canvas: 1_000) { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 250, y: 400, width: 500, height: 200))
        })
        let rendered = try renderedOnDarkTranscript(image: XCTUnwrap(image), backdrop: .light)

        XCTAssertEqual(rendered.color(x: 40, y: 40), [255, 255, 255])
        XCTAssertEqual(rendered.color(x: rendered.width / 2, y: rendered.height / 2), [0, 0, 0])
    }

    func testRenderedContent_whiteLogo_showsTheLogoOnADarkCard() throws {
        let image = try UIImage(data: png(canvas: 1_000) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 250, y: 400, width: 500, height: 200))
        })
        let rendered = try renderedOnDarkTranscript(image: XCTUnwrap(image), backdrop: .dark)

        XCTAssertEqual(rendered.color(x: 40, y: 40), [0x1C, 0x1C, 0x1E])
        XCTAssertEqual(rendered.color(x: rendered.width / 2, y: rendered.height / 2), [255, 255, 255])
    }

    /// Compact chrome is the dark bubble color, which a black logo is just as lost on.
    /// Revert-check: moving the matte branch below the compact check fails this.
    func testRenderedContent_compactPresentation_prefersTheCardOverTheBubbleColor() throws {
        let image = try UIImage(data: png(canvas: 300) { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 100, y: 100, width: 100, height: 100))
        })
        let rendered = try renderedOnDarkTranscript(
            image: XCTUnwrap(image),
            backdrop: .light,
            presentation: .compact
        )

        XCTAssertEqual(rendered.color(x: 20, y: 20), [255, 255, 255])
    }

    /// Revert-check: without `visibleImage` this draws the transparent image with no placeholder,
    /// and the box renders as nothing but transcript black.
    func testRenderedContent_nothingVisible_showsThePlaceholderInsteadOfAnEmptyBox() throws {
        let image = try UIImage(data: png(canvas: 500) { _ in })
        let rendered = try renderedOnDarkTranscript(image: XCTUnwrap(image), backdrop: .nothingVisible)

        // `Color.gray.opacity(0.1)` over black, the failed thumbnail's fill.
        XCTAssertGreaterThan(rendered.color(x: 40, y: 40)[0], 5)
    }

    func testMountedContent_everyBackdrop_keepsTheReservedSize() throws {
        let size = ImageAttachmentLayout.size(
            pixelWidth: 1_000,
            pixelHeight: 1_000,
            maxWidth: 280,
            displayScale: 3,
            presentation: .standard
        )
        let image = try UIImage(data: png(canvas: 1_000) { _ in })
        for backdrop: ImageBackdropPolicy in [.none, .light, .dark, .nothingVisible] {
            let host = try mountInTestWindow(ImageAttachmentBubbleContent(
                image: XCTUnwrap(image),
                isLoading: false,
                filename: "A logo with a long filename that must not resize the attachment.png",
                presentation: .standard,
                size: size,
                backdrop: backdrop
            ))
            let measured = host.sizeThatFits(in: CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
            XCTAssertEqual(measured.width, size.width, accuracy: 0.01)
            XCTAssertEqual(measured.height, size.height, accuracy: 0.01)
        }
    }

    // MARK: - Helpers

    private static let indexedLogoPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAMAAADz0U65AAAABlBMVEX///8AAABVwtN+AAAAAnRSTlMA/1uRIrUAAAASSURBVHicY2DABxiBAJWBCwAAAWgACeAQWKsAAAAASUVORK5CYII="

    private func backdrop(logo: UIColor, canvas: CGFloat) throws -> ImageBackdropPolicy {
        let image = try decodedPNG(canvas: canvas) { context in
            logo.setFill()
            context.fill(CGRect(x: canvas * 0.25, y: canvas * 0.4, width: canvas * 0.5, height: canvas * 0.2))
        }
        return ImageBackdropPolicy.resolve(for: image)
    }

    /// Through encode and decode, so the `CGImage` is the one a thumbnail loads as.
    private func decodedPNG(
        canvas: CGFloat,
        draw: (UIGraphicsImageRendererContext) -> Void
    ) throws -> CGImage {
        try XCTUnwrap(UIImage(data: png(canvas: canvas, draw: draw))?.cgImage)
    }

    private func png(
        canvas: CGFloat,
        draw: (UIGraphicsImageRendererContext) -> Void
    ) throws -> Data {
        UIGraphicsImageRenderer(
            size: CGSize(width: canvas, height: canvas),
            format: oneScaleFormat()
        ).pngData(actions: draw)
    }

    private func oneScaleFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return format
    }

    private func renderedOnDarkTranscript(
        image: UIImage,
        backdrop: ImageBackdropPolicy,
        presentation: InlineImagePresentationPolicy = .standard
    ) throws -> RGBABitmap {
        let size = ImageAttachmentLayout.size(
            pixelWidth: image.size.width,
            pixelHeight: image.size.height,
            maxWidth: 280,
            displayScale: 3,
            presentation: presentation
        )
        let view = ZStack {
            Color.black
            ImageAttachmentBubbleContent(
                image: image,
                isLoading: false,
                filename: "logo.png",
                presentation: presentation,
                size: size,
                backdrop: backdrop
            )
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try rgbaBitmap(of: XCTUnwrap(renderer.cgImage))
    }

    private struct RGBABitmap {
        let bytes: [UInt8]
        let width: Int
        let height: Int

        func color(x: Int, y: Int) -> [UInt8] {
            let offset = (y * width + x) * 4
            return Array(bytes[offset..<(offset + 3)])
        }
    }

    private func rgbaBitmap(of image: CGImage) throws -> RGBABitmap {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let didDraw = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(didDraw)
        return RGBABitmap(bytes: bytes, width: image.width, height: image.height)
    }
}

private extension CGImageAlphaInfo {
    var hasAlphaChannel: Bool {
        switch self {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }
}
