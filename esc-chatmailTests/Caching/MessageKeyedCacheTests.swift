import XCTest
@testable import esc_chatmail

/// CX7: the message-keyed caches share one invalidation contract
/// (`MessageKeyedCache`), and cache version constants live in
/// `CacheVersioning`.
final class MessageKeyedCacheTests: XCTestCase {

    func testAllMessageKeyedCachesShareTheContract() {
        // Compile-level guarantee: every message-keyed cache can be handled
        // through the shared protocol. (RenderedMessageCache and
        // ProcessedTextCache are actors; building the array exercises their
        // conformances too.)
        let caches: [any MessageKeyedCache] = [
            ProcessedTextCache.shared,
            RenderedMessageCache.shared,
            HTMLContentLoader.shared,
            HTMLContentResultCache()
        ]
        XCTAssertEqual(caches.count, 4)
    }

    func testHTMLContentResultCache_invalidateThroughContract_dropsEveryVariant() {
        let cache = HTMLContentResultCache()
        let result = HTMLLoadResult(html: "<p>Hello</p>", source: .messageId)
        cache.store(
            result,
            cacheKey: "key-1" as NSString,
            variantKey: "variant-1" as NSString,
            messageId: "msg-1",
            cost: 16
        )
        XCTAssertNotNil(cache.result(forKey: "key-1" as NSString))

        let keyed: any MessageKeyedCache = cache
        let done = expectation(description: "invalidate")
        Task {
            await keyed.invalidate(messageId: "msg-1", reason: .messageDeleted)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertNil(cache.result(forKey: "key-1" as NSString))
        XCTAssertNil(cache.resultForVariant("variant-1"))
    }

    func testCacheVersioning_isTheSingleHomeForVersionConstants() {
        // Pins the aliasing: the snapshot cache key must embed the shared
        // renderer version so a bump in CacheVersioning invalidates it.
        let key = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: "preview-key",
            renderedHTML: "<p>Hi</p>",
            containerWidth: 320,
            isDarkMode: false
        )
        XCTAssertTrue(key.contains("renderer:\(CacheVersioning.previewSnapshotRendererVersion)"))
        XCTAssertEqual(EmailPreviewSnapshotCacheKey.rendererVersion, CacheVersioning.previewSnapshotRendererVersion)
    }
}
