import XCTest
@testable import esc_chatmail

final class ProcessedTextCacheTests: XCTestCase {

    // MARK: - Cache Operations

    func testCache_setAndGet_returnsCachedValue() async {
        let cache = ProcessedTextCache.shared
        let testId = "test-message-\(UUID().uuidString)"
        let testText = "Hello, this is a test message."

        await cache.set(messageId: testId, plainText: testText, hasRichContent: false)

        let result = await cache.get(messageId: testId)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.plainText, testText)
        XCTAssertFalse(result?.hasRichContent ?? true)

        // Cleanup
        await cache.invalidate(messageId: testId)
    }

    func testCache_getNonexistent_returnsNil() async {
        let cache = ProcessedTextCache.shared
        let result = await cache.get(messageId: "nonexistent-\(UUID().uuidString)")
        XCTAssertNil(result)
    }

    func testCache_invalidate_removesCachedEntry() async {
        let cache = ProcessedTextCache.shared
        let testId = "test-invalidate-\(UUID().uuidString)"

        await cache.set(messageId: testId, plainText: "Test", hasRichContent: false)
        await cache.invalidate(messageId: testId)

        let result = await cache.get(messageId: testId)
        XCTAssertNil(result)
    }

    func testCache_trackedKeysArePrunedAfterLRUEviction() async {
        let cache = ProcessedTextCache.shared
        await cache.clear()

        for index in 0...CacheConfig.textCacheSize {
            await cache.set(
                messageId: "test-lru-\(index)",
                sourceSignature: "source-\(index)",
                previewMode: "test-preview",
                plainText: "Message \(index)",
                hasRichContent: false
            )
        }

        let stats = await cache.getStatistics()
        let trackedKeyCount = await cache.trackedCacheKeyCountForTesting()
        XCTAssertEqual(stats.currentItemCount, CacheConfig.textCacheSize)
        XCTAssertEqual(trackedKeyCount, stats.currentItemCount)

        await cache.clear()
    }

    func testCache_handleMemoryWarningClearsTrackedKeys() async {
        let cache = ProcessedTextCache.shared
        await cache.clear()

        await cache.set(
            messageId: "test-memory-warning-\(UUID().uuidString)",
            sourceSignature: "source",
            previewMode: "test-preview",
            plainText: "Cached text",
            hasRichContent: false
        )

        await cache.handleMemoryWarning()

        let trackedKeyCount = await cache.trackedCacheKeyCountForTesting()
        XCTAssertEqual(trackedKeyCount, 0)

        await cache.clear()
    }

    func testCache_prunePreservesTrackedKeysForInFlightWrites() async {
        let cache = ProcessedTextCache.shared
        await cache.clear()

        let pendingMessageId = "test-pending-write-\(UUID().uuidString)"
        let liveMessageId = "test-live-write-\(UUID().uuidString)"
        await cache.beginTrackedCacheWriteForTesting(
            messageId: pendingMessageId,
            sourceSignature: "pending-source",
            previewMode: "test-preview"
        )

        await cache.set(
            messageId: liveMessageId,
            sourceSignature: "live-source",
            previewMode: "test-preview",
            plainText: "Cached text",
            hasRichContent: false
        )

        let trackedKeyCount = await cache.trackedCacheKeyCountForTesting()
        XCTAssertEqual(trackedKeyCount, 2)

        await cache.finishTrackedCacheWriteForTesting()
        await cache.clear()
    }

    func testCache_setWithQuotedParts_returnsCachedQuotes() async {
        let cache = ProcessedTextCache.shared
        let testId = "test-quotes-\(UUID().uuidString)"
        let quotedParts = [
            QuotedPart(text: "Original message", attribution: "On Jan 1, John wrote:", nestingLevel: 0),
            QuotedPart(text: "Even older message", attribution: nil, nestingLevel: 1)
        ]

        await cache.set(messageId: testId, plainText: "My reply", hasRichContent: false, quotedParts: quotedParts)

        let result = await cache.get(messageId: testId)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.quotedParts.count, 2)
        XCTAssertEqual(result?.quotedParts.first?.text, "Original message")
        XCTAssertEqual(result?.quotedParts.first?.nestingLevel, 0)
        XCTAssertEqual(result?.quotedParts.last?.nestingLevel, 1)

        // Cleanup
        await cache.invalidate(messageId: testId)
    }
}
