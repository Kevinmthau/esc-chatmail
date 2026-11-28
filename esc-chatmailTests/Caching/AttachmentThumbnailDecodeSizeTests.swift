import XCTest
import UniformTypeIdentifiers
@testable import esc_chatmail

/// An attachment's preview is decoded to the frame its view draws it in, and the thumbnail
/// cache charges what the bitmap holds (architecture review 2026-11, caching-memory#1).
final class AttachmentThumbnailDecodeSizeTests: XCTestCase {
    // MARK: - ThumbnailDecodeSize

    func testDecodeSize_roundsEachSideUpToTheStep() throws {
        let size = try XCTUnwrap(ThumbnailDecodeSize(points: CGSize(width: 60, height: 80), displayScale: 3))
        XCTAssertEqual(size.pixelWidth, 256)
        XCTAssertEqual(size.pixelHeight, 256)

        let exact = try XCTUnwrap(ThumbnailDecodeSize(points: CGSize(width: 128, height: 256), displayScale: 1))
        XCTAssertEqual(exact.pixelWidth, 128)
        XCTAssertEqual(exact.pixelHeight, 256)
    }

    func testDecodeSize_ofAnEmptyOrInvalidFrame_isNil() {
        XCTAssertNil(ThumbnailDecodeSize(points: .zero, displayScale: 3))
        XCTAssertNil(ThumbnailDecodeSize(points: CGSize(width: 60, height: 80), displayScale: 0))
        XCTAssertNil(ThumbnailDecodeSize(points: CGSize(width: CGFloat.infinity, height: 80), displayScale: 2))
        XCTAssertNil(ThumbnailDecodeSize(points: CGSize(width: CGFloat.nan, height: 80), displayScale: 2))
    }

    // Revert-check: `max` of the two ratios in `ThumbnailDecodeSize.longerSide(forSourceOf:)`.
    // Take the `min` (fitting the frame) and a page wider than its aspect-fill frame decodes
    // too small to cover it, which draws it soft.
    func testLongerSide_coversTheFrame_neverMoreThanTheSource() throws {
        let photoFrame = try XCTUnwrap(ThumbnailDecodeSize(points: CGSize(width: 280, height: 210), displayScale: 3))
        XCTAssertEqual(photoFrame.longerSide(forSourceOf: CGSize(width: 1_600, height: 1_200)), 896)

        let cardFrame = try XCTUnwrap(ThumbnailDecodeSize(points: CGSize(width: 60, height: 80), displayScale: 3))
        // A landscape page, aspect-fill in a 256 x 256 frame: its shorter side must reach 256.
        let landscape = cardFrame.longerSide(forSourceOf: CGSize(width: 1_600, height: 1_236))
        XCTAssertGreaterThanOrEqual(landscape * 1_236 / 1_600, 256)

        XCTAssertEqual(cardFrame.longerSide(forSourceOf: CGSize(width: 100, height: 50)), 100)
    }

    // MARK: - AttachmentCacheActor

    // Revert-check: decoding to `longerSide(forSourceOf:)` in
    // `AttachmentCacheActor.decodedThumbnail(from:decodeSize:)`. Decode the preview at its own
    // size, as `PlatformImage(data:)` did, and the image is 1,600 pixels wide.
    func testLoadThumbnail_decodesThePreviewToCoverItsFrame() async throws {
        let jpeg = try TestImageData.encoded(as: .jpeg, pixelSizes: [CGSize(width: 1_600, height: 1_200)])
        let cache = AttachmentCacheActor(loadAttachmentData: { _ in jpeg })
        let frame = try XCTUnwrap(ThumbnailDecodeSize(points: CGSize(width: 280, height: 210), displayScale: 3))

        let image = await cache.loadThumbnail(
            for: "local_decode_size",
            from: "Previews/local_decode_size.jpg",
            decodeSize: frame
        )

        let pixelSize = try XCTUnwrap(image).pixelSize
        XCTAssertEqual(max(pixelSize.width, pixelSize.height), 896)
        XCTAssertEqual(min(pixelSize.width, pixelSize.height), 672)
    }

    func testLoadThumbnail_withNoDecodeSize_decodesThePreviewWhole() async throws {
        let jpeg = try TestImageData.encoded(as: .jpeg, pixelSizes: [CGSize(width: 1_600, height: 1_200)])
        let cache = AttachmentCacheActor(loadAttachmentData: { _ in jpeg })

        let image = await cache.loadThumbnail(for: "local_whole", from: "Previews/local_whole.jpg")

        XCTAssertEqual(try XCTUnwrap(image).pixelSize, CGSize(width: 1_600, height: 1_200))
    }

    // Revert-check: `image.estimatedCacheCost` as the thumbnail's cost in
    // `AttachmentCacheActor.loadThumbnail`. Charge the JPEG re-encode's size, as it was, and all
    // three previews fit a budget made for two decoded bitmaps: the first is a hit, and the
    // loader is asked three times, not four.
    func testThumbnailCache_chargesDecodedPixels_soABudgetForTwoKeepsTwo() async throws {
        let jpeg = try TestImageData.encoded(as: .jpeg, pixelSizes: [CGSize(width: 1_600, height: 1_200)])
        let loads = LoadCounter()
        let decodedBytes = 896 * 672 * 4
        let cache = AttachmentCacheActor(
            loadAttachmentData: { _ in
                loads.increment()
                return jpeg
            },
            thumbnailCacheConfiguration: CacheConfiguration(
                maxItems: 500,
                maxMemoryBytes: decodedBytes * 2 + decodedBytes / 2
            )
        )
        let frame = try XCTUnwrap(ThumbnailDecodeSize(points: CGSize(width: 280, height: 210), displayScale: 3))
        let ids = ["local_budget_a", "local_budget_b", "local_budget_c"]

        for id in ids {
            let image = await cache.loadThumbnail(for: id, from: "Previews/\(id).jpg", decodeSize: frame)
            XCTAssertNotNil(image)
        }
        XCTAssertEqual(loads.value, 3)

        for id in ids.dropFirst() {
            _ = await cache.loadThumbnail(for: id, from: "Previews/\(id).jpg", decodeSize: frame)
        }
        XCTAssertEqual(loads.value, 3, "The two most recent previews are kept")

        _ = await cache.loadThumbnail(for: ids[0], from: "Previews/\(ids[0]).jpg", decodeSize: frame)
        XCTAssertEqual(loads.value, 4, "The oldest was evicted to keep the budget")
    }

    func testThumbnailCache_keysTheDecodedSize_soTwoFramesAreTwoEntries() async throws {
        let jpeg = try TestImageData.encoded(as: .jpeg, pixelSizes: [CGSize(width: 1_600, height: 1_200)])
        let loads = LoadCounter()
        let cache = AttachmentCacheActor(loadAttachmentData: { _ in
            loads.increment()
            return jpeg
        })
        let small = try XCTUnwrap(ThumbnailDecodeSize(points: CGSize(width: 60, height: 60), displayScale: 2))
        let large = try XCTUnwrap(ThumbnailDecodeSize(points: CGSize(width: 280, height: 210), displayScale: 2))

        let smallImage = await cache.loadThumbnail(for: "local_two_sizes", from: "Previews/x.jpg", decodeSize: small)
        let largeImage = await cache.loadThumbnail(for: "local_two_sizes", from: "Previews/x.jpg", decodeSize: large)
        _ = await cache.loadThumbnail(for: "local_two_sizes", from: "Previews/x.jpg", decodeSize: small)

        XCTAssertEqual(loads.value, 2)
        XCTAssertLessThan(
            try XCTUnwrap(smallImage).pixelSize.width,
            try XCTUnwrap(largeImage).pixelSize.width
        )
    }
}

extension AttachmentThumbnailDecodeSizeTests {
    // MARK: - The photo bubble's decode size

    // Revert-check: `max(maxWidth, widestMaxWidth ?? 0)` in
    // `ImageAttachmentLayout.previewDecodeSize`. Decode for the narrow column's current width and
    // a window widened to the style's 400 points draws the image upscaled until it remounts.
    func testPreviewDecodeSize_inANarrowMacColumn_coversTheStylesFixedWidth() throws {
        let decodeSize = ImageAttachmentLayout.previewDecodeSize(
            pixelWidth: 1_600,
            pixelHeight: 1_200,
            maxWidth: 124,
            widestMaxWidth: MessageBubbleStyle.mac.imageMaxWidth,
            displayScale: 2,
            largestDisplayScale: 2,
            presentation: .standard
        )

        XCTAssertEqual(decodeSize, ThumbnailDecodeSize(points: CGSize(width: 400, height: 300), displayScale: 2))
    }

    // Revert-check: `max(displayScale, largestDisplayScale)` in
    // `ImageAttachmentLayout.previewDecodeSize`. Decode for a 1x window's scale and the image is
    // drawn at half its pixels once the window moves onto a Retina display.
    func testPreviewDecodeSize_onA1xDisplay_isDecodedForTheLargestConnectedScale() throws {
        let decodeSize = ImageAttachmentLayout.previewDecodeSize(
            pixelWidth: 1_600,
            pixelHeight: 1_200,
            maxWidth: 400,
            widestMaxWidth: 400,
            displayScale: 1,
            largestDisplayScale: 2,
            presentation: .standard
        )

        XCTAssertEqual(decodeSize?.pixelWidth, 896)
        XCTAssertEqual(decodeSize, ThumbnailDecodeSize(points: CGSize(width: 400, height: 300), displayScale: 2))
    }

    func testPreviewDecodeSize_withNoFixedWidth_isTheFrameTheBubbleHas() throws {
        let frame = ImageAttachmentLayout.size(
            pixelWidth: 1_600,
            pixelHeight: 1_200,
            maxWidth: 280,
            displayScale: 3,
            presentation: .standard
        )

        let decodeSize = ImageAttachmentLayout.previewDecodeSize(
            pixelWidth: 1_600,
            pixelHeight: 1_200,
            maxWidth: 280,
            widestMaxWidth: nil,
            displayScale: 3,
            largestDisplayScale: 3,
            presentation: .standard
        )

        XCTAssertEqual(decodeSize, ThumbnailDecodeSize(points: frame, displayScale: 3))
    }

    // MARK: - What the decode measures and costs

    // Revert-check: `ImageProcessor.orientedPixelSize(of:)` in
    // `AttachmentCacheActor.decodedThumbnail`. Measure the photo unturned and a portrait frame
    // decodes it at 1,195 pixels on its longer side where 896 cover it.
    func testLoadThumbnail_ofAPhotoTurnedByItsEXIFOrientation_coversTheFrameAsShown() async throws {
        let jpeg = try Self.jpeg(width: 1_600, height: 1_200, exifOrientation: 6)
        let cache = AttachmentCacheActor(loadAttachmentData: { _ in jpeg })
        let portrait = try XCTUnwrap(ThumbnailDecodeSize(points: CGSize(width: 210, height: 280), displayScale: 3))

        let image = await cache.loadThumbnail(for: "local_oriented", from: "Previews/local_oriented.jpg", decodeSize: portrait)

        let pixelSize = try XCTUnwrap(image).pixelSize
        XCTAssertEqual(pixelSize.height, 896)
        XCTAssertEqual(pixelSize.width, 672)
    }

    // Revert-check: the `bytesPerRow * height` branch of `PlatformImage.estimatedCacheCost`.
    // Without it a 16-bit-per-channel bitmap is charged half what it holds.
    func testEstimatedCacheCost_ofASixteenBitBitmap_isWhatItsRowsHold() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 100,
            height: 50,
            bitsPerComponent: 16,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        ))
        let bitmap = try XCTUnwrap(context.makeImage())

        let cost = PlatformImage(cgImage: bitmap).estimatedCacheCost

        XCTAssertEqual(cost, bitmap.bytesPerRow * 50)
        XCTAssertGreaterThanOrEqual(cost, 100 * 50 * 8)
    }

    // MARK: - From source

    // HONEST SCOPE: from source text. Each view's decode size changes no outcome a test can see
    // without memory measurements: drop one and the preview decodes whole, as it did. And the
    // forced decode (`kCGImageSourceShouldCacheImmediately`) only moves where the decode runs:
    // without it the decode happens on the main thread at the image's first draw.
    func testPreviewViews_passTheirFrame_andTheCacheForcesTheDecode() throws {
        let bubble = try repositorySource("esc-chatmail/Views/Components/Attachments/ImageAttachmentBubble.swift")
        XCTAssertTrue(bubble.contains("decodeSize: previewDecodeSize"))
        XCTAssertTrue(bubble.contains("let widestMaxWidth = MessageBubbleStyle.mac.imageMaxWidth"))
        XCTAssertTrue(bubble.contains("let largestDisplayScale = PlatformScreen.scale"))
        let card = try repositorySource("esc-chatmail/Views/Components/Attachments/PDFAttachmentCard.swift")
        XCTAssertEqual(card.components(separatedBy: "decodeSize: thumbnailDecodeSize").count - 1, 2)
        let draft = try repositorySource("esc-chatmail/Views/Components/DraftAttachmentThumbnail.swift")
        XCTAssertTrue(draft.contains("decodeSize: ThumbnailDecodeSize(points: Self.thumbnailFrame, displayScale: displayScale)"))

        let cache = try repositorySource("esc-chatmail/Services/Caching/AttachmentCacheActor.swift")
        let start = try XCTUnwrap(cache.range(of: "nonisolated static func decodedThumbnail("))
        let end = try XCTUnwrap(cache.range(of: "\n    }\n", range: start.upperBound..<cache.endIndex))
        XCTAssertTrue(cache[start.lowerBound..<end.upperBound].contains("kCGImageSourceShouldCacheImmediately: true"))
    }

    private static func jpeg(width: Int, height: Int, exifOrientation: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: exifOrientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private final class LoadCounter: @unchecked Sendable {
    /// Guarded by `lock`.
    private var count = 0
    private let lock = NSLock()

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
