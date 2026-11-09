#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import esc_chatmail

/// A transparent attachment image draws on whatever the transcript's background is, so a black
/// logo on dark mode's black was a 280pt box with its image loaded and nothing visible in it.
@MainActor
final class ImageBackdropPolicyTests: XCTestCase {
    private var writtenPaths: [String] = []
    private var attachmentIDs: [String] = []

    override func tearDown() async throws {
        writtenPaths.forEach { AttachmentPaths.deleteFile(at: $0) }
        writtenPaths.removeAll()
        for attachmentID in attachmentIDs {
            await AttachmentCacheActor.shared.removeFromCache(attachmentID)
        }
        attachmentIDs.removeAll()
        try await super.tearDown()
    }

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

    /// Revert-check: with `flatArtContentShare` at 0.1, the detail decides the card and this
    /// answers `.neutral`.
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
    /// Revert-check: with a single threshold between dark and light content in
    /// `ImageBackdropPolicy.resolve(for:)`, these gain a card.
    func testResolve_midToneContentOnTransparentCanvas_leavesTheBackgroundAlone() throws {
        for gray: CGFloat in [0.35, 0.45, 0.6] {
            XCTAssertEqual(try backdrop(logo: UIColor(white: gray, alpha: 1), canvas: 500), .none)
        }
    }

    /// A round headshot: 21% transparent corners around a mid-tone photo.
    /// Revert-check: with a single threshold between dark and light content in
    /// `ImageBackdropPolicy.resolve(for:)`, this sits on a square.
    func testResolve_circularMidTonePhoto_leavesTheBackgroundAlone() throws {
        let image = try decodedPNG(canvas: 300) { _ in
            UIColor(white: 0.45, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 300, height: 300)).fill()
        }
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .none)
    }

    /// The dark half is what an average hides: this logo's mean is a mid-tone, so it got no card
    /// and its text vanished on dark mode's black.
    /// Revert-check: back on a mean over the whole image, this answers `.none`.
    func testResolve_blackTextBesideBrightIcon_choosesNeutralBackdrop() throws {
        let yellow = UIColor(red: 1, green: 0xE0 / 255, blue: 0x40 / 255, alpha: 1)
        XCTAssertEqual(try twoToneLogo(text: .black, icon: yellow), .neutral)
    }

    /// Revert-check: back on a mean over the whole image, this answers `.dark`, and the dark card
    /// swallows the text.
    func testResolve_blackTextBesideLargeWhiteIcon_choosesNeutralBackdrop() throws {
        XCTAssertEqual(try twoToneLogo(text: .black, icon: .white, iconSide: 200), .neutral)
    }

    /// The icon reads on anything, so only the text decides, and a white card shows them both.
    /// Revert-check: back on a mean over the whole image, this answers `.none`.
    func testResolve_blackTextBesideMidToneIcon_choosesLightBackdrop() throws {
        XCTAssertEqual(try twoToneLogo(text: .black, icon: Self.midToneBlue), .light)
    }

    /// Revert-check: back on a mean over the whole image, this answers `.none`.
    func testResolve_whiteTextBesideMidToneIcon_choosesDarkBackdrop() throws {
        XCTAssertEqual(try twoToneLogo(text: .white, icon: Self.midToneBlue), .dark)
    }

    /// Pure red reads on black, so nothing here is dark and a dark card shows it all.
    /// Revert-check: with `darkContentLuminanceCeiling` compared against encoded luma, red counts
    /// as dark and this answers `.neutral`.
    func testResolve_whiteTextBesideRedIcon_choosesDarkBackdrop() throws {
        XCTAssertEqual(try twoToneLogo(text: .white, icon: .red), .dark)
    }

    /// The badge keeps its glyph readable on anything, so neither gets a card, however much of the
    /// badge the glyph covers.
    /// Revert-check: fails if `samplesExposedToTheBackground` counts every dark and light sample:
    /// each of these then sits on a square.
    func testResolve_glyphInsideABadge_leavesTheBackgroundAlone() throws {
        let orange = UIColor(red: 1, green: 0.55, blue: 0, alpha: 1)
        let cases: [(badge: UIColor, glyph: UIColor)] = [
            (.red, .white), (Self.midToneBlue, .white), (orange, .black)
        ]
        for (badge, glyph) in cases {
            let image = try decodedPNG(canvas: 400) { context in
                badge.setFill()
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 400, height: 400)).fill()
                glyph.setFill()
                context.fill(CGRect(x: 120, y: 120, width: 160, height: 160))
            }
            XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .none)
        }
    }

    /// Revert-check: fails if `samplesExposedToTheBackground` counts every dark and light sample.
    func testResolve_whiteTextInsideABlueBanner_leavesTheBackgroundAlone() throws {
        let image = try decodedPNG(canvas: 400) { context in
            Self.midToneBlue.setFill()
            context.fill(CGRect(x: 0, y: 100, width: 400, height: 200))
            UIColor.white.setFill()
            context.fill(CGRect(x: 60, y: 170, width: 280, height: 60))
        }
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .none)
    }

    /// The sticker's white is what a white transcript swallows, and its black text was never at
    /// risk, so this wants a dark card, not the two-tone gray.
    /// Revert-check: fails if `samplesExposedToTheBackground` counts every dark and light sample:
    /// the text then reads as a second tone and this answers `.neutral`.
    func testResolve_blackTextOnAWhiteSticker_choosesDarkBackdrop() throws {
        let image = try decodedPNG(canvas: 400) { context in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 400, height: 400)).fill()
            UIColor.black.setFill()
            context.fill(CGRect(x: 120, y: 120, width: 160, height: 160))
        }
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .dark)
    }

    /// No sample here is fully transparent, but the whole image lets the background through.
    /// Revert-check: fails if `samplesExposedToTheBackground` stops counting the image's outer
    /// edge: nothing is left to start from, and this answers `.none`.
    func testResolve_translucentDarkImage_choosesLightBackdrop() throws {
        let image = try decodedPNG(canvas: 300) { context in
            UIColor(white: 0, alpha: 0.5).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .light)
    }

    /// Shadows and highlights, all the way across the range: a photo, not a two-tone logo.
    /// Revert-check: with `photoContentShare` set to `flatArtContentShare`, this sits on a gray square.
    func testResolve_roundPhotoWithShadowsAndHighlights_leavesTheBackgroundAlone() throws {
        let image = try decodedPNG(canvas: 320) { context in
            self.fillRoundToneRamp(from: 0, to: 1, canvas: 320, context: context)
        }
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .none)
    }

    /// The photo the `isFlatArt` constants are measured against: real areas of pure white and pure
    /// black, with the mid-tones between them still spread across several bins.
    /// Revert-check: with `flatArtMinimumToneShare` at 0.6, this counts as flat art and sits on a
    /// gray square.
    func testResolve_roundPhotoOnWhiteWithBlackJacket_leavesTheBackgroundAlone() throws {
        let image = try decodedPNG(canvas: 320) { context in
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 320, height: 320)).addClip()
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 130))
            for row in 130..<250 {
                UIColor(white: 0.35 + 0.25 * CGFloat(row - 130) / 120, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: CGFloat(row), width: 320, height: 1))
            }
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 250, width: 320, height: 70))
        }
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .none)
    }

    /// Revert-check: with no card for anything that isn't flat art, this stays lost on black.
    func testResolve_mostlyShadowPhoto_choosesLightBackdrop() throws {
        let image = try decodedPNG(canvas: 320) { context in
            self.fillRoundToneRamp(from: 0, to: 0.5, canvas: 320, context: context)
        }
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .light)
    }

    /// Revert-check: with no card for anything that isn't flat art, this stays lost on white.
    func testResolve_mostlyHighlightPhoto_choosesDarkBackdrop() throws {
        let image = try decodedPNG(canvas: 320) { context in
            self.fillRoundToneRamp(from: 0.5, to: 1, canvas: 320, context: context)
        }
        XCTAssertEqual(ImageBackdropPolicy.resolve(for: image), .dark)
    }

    /// Bright, saturated and plainly visible on white, though their luminance alone says otherwise.
    /// Revert-check: with `lightContentLuminanceFloor` at 0.38, these sit on a dark square.
    func testResolve_brightOrangeAndSkyBlueLogos_leaveTheBackgroundAlone() throws {
        let orange = UIColor(red: 1, green: 0.55, blue: 0, alpha: 1)
        let skyBlue = UIColor(red: 0.35, green: 0.7, blue: 1, alpha: 1)
        XCTAssertEqual(try backdrop(logo: orange, canvas: 500), .none)
        XCTAssertEqual(try backdrop(logo: skyBlue, canvas: 500), .none)
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
    /// Revert-check: without `ImageBackdropPolicy.resolve(for:)`'s `visibleCoverage` guard this
    /// divides by zero coverage and falls through to `.none`, leaving the box empty.
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

    // MARK: - Resolving off the main actor

    /// Revert-check: fails if `resolve(for:analyze:)` stops reading the stored verdict.
    func testResolveImage_sameImageTwice_checksThePixelsOnce() async throws {
        let image = try XCTUnwrap(UIImage(data: blackLogoPNG()))
        let counter = AnalysisCounter()
        let analyze: @Sendable (CGImage) -> ImageBackdropPolicy = { cgImage in
            counter.increment()
            return ImageBackdropPolicy.resolve(for: cgImage)
        }

        let first = await ImageBackdropPolicy.resolve(for: image, analyze: analyze)
        let second = await ImageBackdropPolicy.resolve(for: image, analyze: analyze)

        XCTAssertEqual(first, .light)
        XCTAssertEqual(second, .light)
        XCTAssertEqual(counter.count, 1)
    }

    /// A cancelled check's `.none` is only a stand-in for no answer. Stored, it would take the
    /// image's card away for good.
    /// Revert-check: fails if `resolve(for:analyze:)` drops both of its `Task.isCancelled` guards.
    /// HONEST SCOPE: with only the one inside the detached task gone this still passes, because
    /// the outer guard stops an already cancelled caller first. That inner guard covers a cancel
    /// landing between the spawn and the task starting, which no test here can hold open.
    func testResolveImage_callerAlreadyCancelled_skipsTheCheckAndStoresNothing() async throws {
        let image = try XCTUnwrap(UIImage(data: blackLogoPNG()))
        let counter = AnalysisCounter()

        let cancelled = Task { () -> ImageBackdropPolicy in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ImageBackdropPolicy.resolve(for: image, analyze: { cgImage in
                counter.increment()
                return ImageBackdropPolicy.resolve(for: cgImage)
            })
        }
        let cancelledVerdict = await cancelled.value

        XCTAssertEqual(cancelledVerdict, .none)
        XCTAssertEqual(counter.count, 0)
        XCTAssertNil(ImageBackdropPolicy.storedVerdict(for: image))
        let liveVerdict = await ImageBackdropPolicy.resolve(for: image)
        XCTAssertEqual(liveVerdict, .light)
    }

    // MARK: - The thumbnail this policy never sees

    /// Keeps the metadata check honest against what `generateThumbnail` really does, on either
    /// side of its limit.
    /// Revert-check: fails if `thumbnailFlattensTransparency` compares with `>=`, or against any
    /// limit but `maxThumbnailDimension`.
    func testThumbnailFlattensTransparency_agreesWithGenerateThumbnail() throws {
        for canvas: CGFloat in [1_600, 1_601] {
            let original = try png(canvas: canvas) { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 400, y: 600, width: 800, height: 300))
            }
            let thumbnail = ImageProcessor.generateThumbnail(from: original, mimeType: "image/png")
            XCTAssertEqual(
                ImageProcessor.thumbnailFlattensTransparency(
                    pixelWidth: canvas,
                    pixelHeight: canvas,
                    mimeType: "image/png"
                ),
                thumbnail != original,
                "canvas \(canvas)"
            )
        }
    }

    /// A HEIC is an iPhone photo: it must keep its small preview rather than decode the original.
    /// Revert-check: fails if `logoMimeTypes` gains JPEG or HEIC, loses a logo format, or if
    /// `thumbnailFlattensTransparency` looks at one dimension only.
    func testThumbnailFlattensTransparency_answersFromMetadata() {
        func flattens(_ width: CGFloat, _ height: CGFloat, _ mimeType: String) -> Bool {
            ImageProcessor.thumbnailFlattensTransparency(
                pixelWidth: width,
                pixelHeight: height,
                mimeType: mimeType
            )
        }

        XCTAssertTrue(flattens(2_000, 100, "image/png"))
        XCTAssertTrue(flattens(100, 2_000, "image/webp"))
        XCTAssertTrue(flattens(2_000, 2_000, " IMAGE/PNG "))
        XCTAssertTrue(flattens(2_000, 2_000, "image/gif"))
        XCTAssertFalse(flattens(2_000, 2_000, "image/jpeg"))
        XCTAssertFalse(flattens(2_000, 2_000, "image/jpg"))
        XCTAssertFalse(flattens(2_000, 2_000, "image/heic"))
        XCTAssertFalse(flattens(2_000, 2_000, "image/heif"))
        XCTAssertFalse(flattens(2_000, 2_000, "application/pdf"))
        XCTAssertFalse(flattens(1_000, 1_000, "image/png"))
        // Unknown dimensions: the thumbnail is all there is to go on.
        XCTAssertFalse(flattens(0, 0, "image/png"))
    }

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
    /// now. Revert-check: without `ImageAttachmentBubbleContent.backgroundColor`'s read of
    /// `ImageBackdropPolicy.cardColor(for:)` every pixel here renders black and the white assertion fails.
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
    /// Revert-check: with `ImageBackdropPolicy.cardColor(for:)` checking the compact chrome before
    /// the matte, this fails.
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

    /// Revert-check: without `ImageBackdropPolicy.visibleImage(_:)`'s `.nothingVisible` check this
    /// draws the transparent image with no placeholder,
    /// and the box renders as nothing but transcript black.
    func testRenderedContent_nothingVisible_showsThePlaceholderInsteadOfAnEmptyBox() throws {
        let image = try UIImage(data: png(canvas: 500) { _ in })
        let rendered = try renderedOnDarkTranscript(image: XCTUnwrap(image), backdrop: .nothingVisible)

        // `Color.gray.opacity(0.1)` over black, the failed thumbnail's fill.
        XCTAssertGreaterThan(rendered.color(x: 40, y: 40)[0], 5)
    }

    /// Either half alone would be lost on a white or a dark card; here both are on the same one.
    /// Revert-check: without `matteColor`'s `.neutral` branch the corner renders transcript black.
    func testRenderedContent_twoToneLogo_showsBothHalvesOnAGrayCard() throws {
        let image = try UIImage(data: png(canvas: 1_000) { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 100, y: 100, width: 300, height: 800))
            UIColor.white.setFill()
            context.fill(CGRect(x: 600, y: 100, width: 300, height: 800))
        })
        let rendered = try renderedOnDarkTranscript(image: XCTUnwrap(image), backdrop: .neutral)

        XCTAssertEqual(rendered.color(x: rendered.width / 2, y: rendered.height / 2), [0x76, 0x76, 0x76])
        XCTAssertEqual(rendered.color(x: rendered.width / 4, y: rendered.height / 2), [0, 0, 0])
        XCTAssertEqual(rendered.color(x: rendered.width * 3 / 4, y: rendered.height / 2), [255, 255, 255])
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
        for backdrop: ImageBackdropPolicy in [.none, .light, .dark, .neutral, .nothingVisible] {
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

    // MARK: - The grid cell

    /// Revert-check: fails if the standard branch of `AttachmentGridThumbnail` drops its card.
    func testGridThumbnail_darkLogo_showsTheLogoOnALightCard() throws {
        let rendered = try renderedGridCell(image: blackLogoImage(), backdrop: .light)

        XCTAssertEqual(rendered.color(x: 10, y: 10), [255, 255, 255])
        XCTAssertEqual(rendered.color(x: 100, y: 100), [0, 0, 0])
    }

    func testGridThumbnail_lightLogo_showsTheLogoOnADarkCard() throws {
        let image = try XCTUnwrap(UIImage(data: png(canvas: 1_000) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 250, y: 400, width: 500, height: 200))
        }))
        let rendered = try renderedGridCell(image: image, backdrop: .dark)

        XCTAssertEqual(rendered.color(x: 10, y: 10), [0x1C, 0x1C, 0x1E])
        XCTAssertEqual(rendered.color(x: 100, y: 100), [255, 255, 255])
    }

    func testGridThumbnail_twoToneLogo_showsItOnAGrayCard() throws {
        let rendered = try renderedGridCell(image: blackLogoImage(), backdrop: .neutral)

        XCTAssertEqual(rendered.color(x: 10, y: 10), [0x76, 0x76, 0x76])
        XCTAssertEqual(rendered.color(x: 100, y: 100), [0, 0, 0])
    }

    /// No backdrop stays no backdrop: a headshot must not gain a square here either.
    /// Revert-check: fails if `ImageBackdropPolicy.cardColor(for:)` gives the standard presentation a
    /// card when there is no matte.
    func testGridThumbnail_noBackdrop_leavesTheTranscriptShowing() throws {
        let rendered = try renderedGridCell(image: blackLogoImage(), backdrop: .none)

        XCTAssertEqual(rendered.color(x: 10, y: 10), [0, 0, 0])
    }

    /// Revert-check: fails if `AttachmentGridThumbnail` stops asking `ImageBackdropPolicy.visibleImage(_:)`: the
    /// transparent image draws with no placeholder, and the cell is nothing but transcript black.
    func testGridThumbnail_nothingVisible_showsThePlaceholder() throws {
        let image = try XCTUnwrap(UIImage(data: png(canvas: 500) { _ in }))
        let rendered = try renderedGridCell(image: image, backdrop: .nothingVisible)

        // `Color.gray.opacity(0.1)` over black, the placeholder's fill.
        XCTAssertGreaterThan(rendered.color(x: 10, y: 10)[0], 5)
    }

    /// Compact chrome is the dark bubble color, which a black logo is just as lost on.
    /// Revert-check: fails if the compact branch of `AttachmentGridThumbnail` drops its card.
    func testGridThumbnail_compactPresentation_prefersTheCardOverTheBubbleColor() throws {
        let rendered = try renderedGridCell(
            image: blackLogoImage(),
            backdrop: .light,
            presentation: .compact
        )

        XCTAssertEqual(rendered.color(x: 2, y: 2), [255, 255, 255])
    }

    /// Revert-check: fails if `ImageBackdropPolicy.cardColor(for:)` stops falling back to the bubble
    /// color for the compact presentation.
    func testGridThumbnail_compactWithNoBackdrop_keepsTheBubbleColor() throws {
        let rendered = try renderedGridCell(
            image: blackLogoImage(),
            backdrop: .none,
            presentation: .compact
        )

        // `Color.gray.opacity(0.2)` over black.
        XCTAssertGreaterThan(rendered.color(x: 2, y: 2)[0], 5)
        XCTAssertLessThan(rendered.color(x: 2, y: 2)[0], 60)
    }

    // MARK: - The shared view decisions

    /// The bubble and the grid both ask the policy, so each case has one answer for both.
    /// Revert-check: fails if `ImageBackdropPolicy.visibleImage(_:)` stops hiding a `.nothingVisible`
    /// image, or hides any other case's.
    func testVisibleImage_onlyNothingVisibleTakesThePlaceholder() throws {
        let image = try XCTUnwrap(UIImage(data: png(canvas: 10) { _ in }))
        XCTAssertNil(ImageBackdropPolicy.nothingVisible.visibleImage(image))
        for backdrop: ImageBackdropPolicy in [.none, .light, .dark, .neutral] {
            XCTAssertTrue(backdrop.visibleImage(image) === image, "\(backdrop)")
        }
        XCTAssertNil(ImageBackdropPolicy.light.visibleImage(nil))
    }

    /// Revert-check: fails if `ImageBackdropPolicy.cardColor(for:)` puts the compact chrome ahead of
    /// the matte, drops the chrome fallback, or gives the standard presentation a card of its own.
    func testCardColor_matteWinsThenCompactChromeThenNothing() {
        let bubbleColor = MessageBubbleStyle.standard.recipientBubbleColor()
        for presentation: InlineImagePresentationPolicy in [.standard, .compact] {
            XCTAssertEqual(ImageBackdropPolicy.light.cardColor(for: presentation), .white)
            XCTAssertEqual(
                ImageBackdropPolicy.neutral.cardColor(for: presentation),
                ImageBackdropPolicy.neutral.matteColor
            )
        }
        XCTAssertEqual(ImageBackdropPolicy.none.cardColor(for: .compact), bubbleColor)
        XCTAssertNil(ImageBackdropPolicy.none.cardColor(for: .standard))
        XCTAssertNil(ImageBackdropPolicy.nothingVisible.cardColor(for: .standard))
    }

    // MARK: - Real views, real files

    /// The grid item's own wiring, from the file on disk to the pixels on screen.
    /// Revert-check: fails if `AttachmentGridItem` stops passing `imageBackdrop` to its thumbnail.
    func testMountedGridItem_darkLogo_showsTheLogoOnALightCard() async throws {
        let (attachment, downloader) = try makeDownloadedAttachment(
            localData: blackLogoPNG(),
            previewData: nil,
            pixelSide: 1_000
        )
        let host = try mountOnDarkTranscript(
            AttachmentGridItem(
                attachment: attachment,
                downloader: downloader,
                showOverlay: false,
                overlayCount: 0,
                onTap: {}
            )
            .frame(width: 200, height: 200)
        )

        await waitUntilSnapshot(of: host) { bitmap in
            bitmap.color(x: 10, y: 10) == [255, 255, 255] && bitmap.color(x: 100, y: 100) == [0, 0, 0]
        }
    }

    /// The finding end to end: a white logo over the thumbnail limit, its preview already
    /// flattened to a white JPEG, in a single-attachment bubble.
    /// Revert-check: fails if `ImageAttachmentBubble.loadThumbnail` always reads the thumbnail:
    /// the box stays blank white and the card never appears.
    func testMountedBubble_oversizedWhiteLogo_showsTheLogoOnADarkCard() async throws {
        let original = try png(canvas: 2_000) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 500, y: 800, width: 1_000, height: 400))
        }
        let (attachment, downloader) = try makeDownloadedAttachment(
            localData: original,
            previewData: XCTUnwrap(ImageProcessor.generateThumbnail(from: original, mimeType: "image/png")),
            pixelSide: 2_000
        )
        let host = try mountOnDarkTranscript(
            ImageAttachmentBubble(attachment: attachment, downloader: downloader, onTap: {})
        )

        await waitUntilSnapshot(of: host) { $0.color(x: 20, y: 20) == [0x1C, 0x1C, 0x1E] }
    }

    /// The original can land after its preview, under a path the preview load never looked at.
    /// Revert-check: fails if `ImageAttachmentBubble` drops `.onChange(of: attachment.localURL)`:
    /// the flattened preview stays up until the row remounts.
    func testMountedBubble_originalArrivingAfterItsPreview_showsTheCard() async throws {
        let original = try png(canvas: 2_000) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 500, y: 800, width: 1_000, height: 400))
        }
        let attachmentID = "local_backdrop-test-\(UUID().uuidString)"
        attachmentIDs.append(attachmentID)
        // Uploading with no local file yet starts no download.
        let attachment = try AttachmentBuilder()
            .withId(attachmentID)
            .asImage(width: 2_000, height: 2_000)
            .withMimeType("image/png")
            .withFilename("logo.png")
            .downloading()
            .withPreviewURL(write(XCTUnwrap(ImageProcessor.generateThumbnail(from: original, mimeType: "image/png"))))
            .build(in: TestCoreDataStack().makeMainQueueViewContext())
        let downloader = AttachmentDownloader(
            apiClient: MockGmailAPIClient(),
            prepareDownloadDirectories: {}
        )
        let host = try mountOnDarkTranscript(
            ImageAttachmentBubble(attachment: attachment, downloader: downloader, onTap: {})
        )
        // The flattened preview, dimmed as an attachment still in flight is, but well above the
        // placeholder's fill.
        await waitUntilSnapshot(of: host) { $0.color(x: 20, y: 20)[0] > 40 }

        attachment.localURL = try write(original)
        attachment.state = .downloaded
        downloader.objectWillChange.send()

        await waitUntilSnapshot(of: host) { $0.color(x: 20, y: 20) == [0x1C, 0x1C, 0x1E] }
    }

    /// Within the limit the thumbnail holds the same bytes, so the original is never read. The two
    /// files differ here only so the card shows which one was.
    /// Revert-check: fails if `thumbnailFlattensTransparency` answers true at any size: the white
    /// logo on disk would bring a dark card instead.
    func testMountedBubble_withinTheLimit_readsTheThumbnail() async throws {
        let whiteLogo = try png(canvas: 1_000) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 250, y: 400, width: 500, height: 200))
        }
        let (attachment, downloader) = try makeDownloadedAttachment(
            localData: whiteLogo,
            previewData: blackLogoPNG(),
            pixelSide: 1_000
        )
        let host = try mountOnDarkTranscript(
            ImageAttachmentBubble(attachment: attachment, downloader: downloader, onTap: {})
        )

        await waitUntilSnapshot(of: host) { $0.color(x: 20, y: 20) == [255, 255, 255] }
    }

    // MARK: - Helpers

    private static let midToneBlue = UIColor(red: 0x0A / 255, green: 0x84 / 255, blue: 1, alpha: 1)

    /// Lock-guarded because the analysis runs off the MainActor.
    private final class AnalysisCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0

        var count: Int { lock.withLock { _count } }

        func increment() {
            lock.withLock { _count += 1 }
        }
    }

    /// A solid icon over a thin line of text, about the proportions of a real lockup.
    private func twoToneLogo(
        text: UIColor,
        icon: UIColor,
        iconSide: CGFloat = 160
    ) throws -> ImageBackdropPolicy {
        let image = try decodedPNG(canvas: 400) { context in
            icon.setFill()
            context.fill(CGRect(x: 200 - iconSide / 2, y: 40, width: iconSide, height: iconSide))
            text.setFill()
            context.fill(CGRect(x: 60, y: 320, width: 280, height: 40))
        }
        return ImageBackdropPolicy.resolve(for: image)
    }

    /// A circle of smoothly changing tone, the shape and tonal spread of a round photo.
    private func fillRoundToneRamp(
        from start: CGFloat,
        to end: CGFloat,
        canvas: Int,
        context: UIGraphicsImageRendererContext
    ) {
        let side = CGFloat(canvas)
        UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).addClip()
        for row in 0..<canvas {
            UIColor(white: start + (end - start) * CGFloat(row) / side, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: CGFloat(row), width: side, height: 1))
        }
    }

    private func blackLogoPNG() throws -> Data {
        try png(canvas: 1_000) { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 250, y: 400, width: 500, height: 200))
        }
    }

    private func blackLogoImage() throws -> UIImage {
        try XCTUnwrap(UIImage(data: blackLogoPNG()))
    }

    private func renderedGridCell(
        image: UIImage,
        backdrop: ImageBackdropPolicy,
        presentation: InlineImagePresentationPolicy = .standard
    ) throws -> RGBABitmap {
        let view = ZStack {
            Color.black
            AttachmentGridThumbnail(
                image: image,
                backdrop: backdrop,
                isLoading: false,
                placeholderIconName: "photo",
                presentation: presentation,
                pixelSize: CGSize(width: 1_000, height: 1_000),
                cellSize: CGSize(width: 200, height: 200)
            )
        }
        .frame(width: 200, height: 200)
        .environment(\.colorScheme, .dark)
        .environment(\.displayScale, 3)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try rgbaBitmap(of: XCTUnwrap(renderer.cgImage))
    }

    /// A downloaded PNG attachment over real files. `local_` IDs need no message-scoped path to
    /// read as storage, and a local file on disk starts no download.
    private func makeDownloadedAttachment(
        localData: Data,
        previewData: Data?,
        pixelSide: Int16
    ) throws -> (Attachment, AttachmentDownloader) {
        let attachmentID = "local_backdrop-test-\(UUID().uuidString)"
        attachmentIDs.append(attachmentID)
        var builder = AttachmentBuilder()
            .withId(attachmentID)
            .asImage(width: pixelSide, height: pixelSide)
            .withMimeType("image/png")
            .withFilename("logo.png")
            .downloaded()
            .withLocalURL(try write(localData))
        if let previewData {
            builder = builder.withPreviewURL(try write(previewData))
        }
        let attachment = builder.build(in: TestCoreDataStack().makeMainQueueViewContext())
        let downloader = AttachmentDownloader(
            apiClient: MockGmailAPIClient(),
            prepareDownloadDirectories: {}
        )
        return (attachment, downloader)
    }

    private func write(_ data: Data) throws -> String {
        AttachmentPaths.setupDirectories()
        let path = AttachmentPaths.previewPath(
            idOrUUID: "backdrop-test-\(UUID().uuidString)",
            ext: "png"
        )
        XCTAssertTrue(AttachmentPaths.saveData(data, to: path))
        writtenPaths.append(path)
        return path
    }

    /// Pinned to the window's top-left corner, so a sample's position is the view's own.
    private func mountOnDarkTranscript<Content: View>(
        _ content: Content
    ) throws -> UIHostingController<some View> {
        try mountInTestWindow(
            ZStack(alignment: .topLeading) {
                Color.black
                content
            }
            .environment(\.colorScheme, .dark)
        )
    }

    private func snapshot<Content: View>(of host: UIHostingController<Content>) throws -> RGBABitmap {
        let bounds = host.view.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        return try rgbaBitmap(of: XCTUnwrap(image.cgImage))
    }

    private func waitUntilSnapshot<Content: View>(
        of host: UIHostingController<Content>,
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: (RGBABitmap) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let bitmap = try? snapshot(of: host), condition(bitmap) { return }
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the rendered condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

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
#endif
