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
