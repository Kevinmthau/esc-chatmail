import XCTest
import UIKit
@testable import esc_chatmail

/// Verifies the image caches pass a cost with every insertion. Eviction
/// itself is advisory NSCache behavior and is deliberately not asserted;
/// these tests pin the cost formula and the wiring (no cost-less setObject).
final class ImageCacheCostTests: XCTestCase {

    // MARK: - Spies
    //
    // NSCache is an Objective-C generic, so subclasses must bind concrete
    // types — one spy per cached value type, sharing a recorder.
    // A cost-less setObject records -1.

    private final class CostRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var costs: [Int] = []

        var recordedCosts: [Int] {
            lock.lock(); defer { lock.unlock() }
            return costs
        }

        func record(_ cost: Int) {
            lock.lock(); costs.append(cost); lock.unlock()
        }
    }

    private final class CostRecordingImageCache: NSCache<NSString, UIImage>, @unchecked Sendable {
        let recorder = CostRecorder()

        override func setObject(_ obj: UIImage, forKey key: NSString, cost g: Int) {
            recorder.record(g)
            super.setObject(obj, forKey: key, cost: g)
        }

        override func setObject(_ obj: UIImage, forKey key: NSString) {
            recorder.record(-1)
            super.setObject(obj, forKey: key)
        }
    }

    private final class CostRecordingPhotoCache: NSCache<NSString, CachedPhoto>, @unchecked Sendable {
        let recorder = CostRecorder()

        override func setObject(_ obj: CachedPhoto, forKey key: NSString, cost g: Int) {
            recorder.record(g)
            super.setObject(obj, forKey: key, cost: g)
        }

        override func setObject(_ obj: CachedPhoto, forKey key: NSString) {
            recorder.record(-1)
            super.setObject(obj, forKey: key)
        }
    }

    private func makeImage(width: Int, height: Int, scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    // MARK: - Formula

    func testEstimatedCacheCost_usesPixelDimensions() {
        let image = makeImage(width: 10, height: 20, scale: 2)
        // 10pt × 20pt at 2× scale → 4 bytes per pixel × scale² = 3200
        XCTAssertEqual(image.estimatedCacheCost, 10 * 20 * 4 * 2 * 2)
    }

    func testCachedPhotoCost_isCompressedDataSize() {
        let data = Data(repeating: 0xAB, count: 12_345)
        let photo = ProfilePhoto(source: .contacts, imageData: data, url: nil)
        XCTAssertEqual(CachedPhoto(photo: photo, timestamp: Date()).estimatedCacheCost, 12_345)
    }

    func testCachedPhotoCost_nilAndURLEntriesAreFree() {
        XCTAssertEqual(CachedPhoto(photo: nil, timestamp: Date()).estimatedCacheCost, 0)
        let urlOnly = ProfilePhoto(source: .cached, imageData: nil, url: "https://example.com/a.png")
        XCTAssertEqual(CachedPhoto(photo: urlOnly, timestamp: Date()).estimatedCacheCost, 0)
    }

    // MARK: - Wiring

    func testEnhancedImageCache_setPassesPixelCost() async {
        let spy = CostRecordingImageCache()
        let cache = EnhancedImageCache(memoryCache: spy)
        let image = makeImage(width: 8, height: 8, scale: 1)

        await cache.set(image, for: "cost-test-\(UUID().uuidString)")

        XCTAssertEqual(spy.recorder.recordedCosts, [image.estimatedCacheCost])
        XCTAssertFalse(spy.recorder.recordedCosts.contains(-1), "cost-less setObject reintroduced")
    }

    func testEnhancedImageCache_base64DecodePassesPixelCost() async {
        let spy = CostRecordingImageCache()
        let cache = EnhancedImageCache(memoryCache: spy)
        guard let pngData = makeImage(width: 4, height: 4).pngData() else {
            return XCTFail("could not encode fixture image")
        }
        let dataURL = "data:image/png;base64,\(pngData.base64EncodedString())"

        let image = await cache.loadImage(from: dataURL)

        XCTAssertNotNil(image)
        XCTAssertEqual(spy.recorder.recordedCosts.count, 1)
        XCTAssertGreaterThan(spy.recorder.recordedCosts[0], 0)
        XCTAssertFalse(spy.recorder.recordedCosts.contains(-1), "cost-less setObject reintroduced")
    }

    func testProfilePhotoResolver_negativeCacheEntryCostsZero() async {
        let spy = CostRecordingPhotoCache()
        let resolver = ProfilePhotoResolver(cache: spy)

        // Unknown address: no contact, no cached URL → nil photo is cached
        // as a negative entry with zero cost.
        _ = await resolver.resolvePhoto(for: "nobody-\(UUID().uuidString)@example.com")

        XCTAssertEqual(spy.recorder.recordedCosts, [0])
        XCTAssertFalse(spy.recorder.recordedCosts.contains(-1), "cost-less setObject reintroduced")
    }
}
