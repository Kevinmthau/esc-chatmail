import XCTest
import CoreData
@testable import esc_chatmail

/// Characterization tests for `ConversationCache` core operations.
///
/// Pins the deterministic behavior of the in-memory conversation cache that the
/// cache-consolidation work will later absorb: set/get hit + miss, invalidate,
/// clear, item-count + memory bookkeeping, and the item-count LRU cap.
///
/// Not covered (intentionally): the 300s `Date()`-based TTL expiry path, which
/// has no injectable clock and so cannot be exercised deterministically. When
/// consolidation introduces an injectable clock, add expiry coverage here.
///
/// `ConversationCache` is a `@MainActor` singleton, so each test resets it via
/// `clearAllCaches()` (which — unlike `clear()` — also resets hit/miss stats).
@MainActor
final class ConversationCacheTests: XCTestCase {

    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var cache: ConversationCache!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.viewContext
        cache = ConversationCache.shared
        cache.clearAllCaches()
    }

    override func tearDown() {
        cache.clearAllCaches()
        cache = nil
        context = nil
        stack = nil
        super.tearDown()
    }

    private func makeConversation(id: UUID = UUID()) -> Conversation {
        ConversationBuilder().withId(id).build(in: context)
    }

    // MARK: - set / get

    func testSetThenGet_returnsCachedConversationAndRecordsHit() {
        let id = UUID()
        let conversation = makeConversation(id: id)
        let message = MessageBuilder().inConversation(conversation).build(in: context)

        cache.set(conversation, messages: [message])
        let cached = cache.get(id.uuidString)

        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.id, id.uuidString)
        XCTAssertEqual(cached?.messages.count, 1)
        XCTAssertEqual(cache.getStatistics().hits, 1)
        XCTAssertEqual(cache.getStatistics().misses, 0)
    }

    func testGetUnknownId_returnsNilAndRecordsMiss() {
        let cached = cache.get(UUID().uuidString)

        XCTAssertNil(cached)
        XCTAssertEqual(cache.getStatistics().hits, 0)
        XCTAssertEqual(cache.getStatistics().misses, 1)
    }

    func testSet_updatesItemCountAndMemoryUsage() {
        let conversation = makeConversation()
        let message = MessageBuilder().inConversation(conversation).build(in: context)

        cache.set(conversation, messages: [message])

        XCTAssertEqual(cache.cacheItemCount, 1)
        XCTAssertGreaterThan(cache.currentMemoryUsage, 0)
    }

    func testSetSameConversationTwice_keepsSingleEntry() {
        let id = UUID()
        let conversation = makeConversation(id: id)

        cache.set(conversation, messages: [])
        cache.set(conversation, messages: [])

        XCTAssertEqual(cache.cacheItemCount, 1)
    }

    // MARK: - invalidate / clear

    func testInvalidate_removesEntry() {
        let id = UUID()
        let conversation = makeConversation(id: id)
        cache.set(conversation, messages: [])
        XCTAssertNotNil(cache.get(id.uuidString))

        cache.invalidate(id.uuidString)

        XCTAssertNil(cache.get(id.uuidString))
        XCTAssertEqual(cache.cacheItemCount, 0)
    }

    func testClear_emptiesCacheAndResetsBookkeeping() {
        let conversation = makeConversation()
        let message = MessageBuilder().inConversation(conversation).build(in: context)
        cache.set(conversation, messages: [message])

        cache.clear()

        XCTAssertEqual(cache.cacheItemCount, 0)
        XCTAssertEqual(cache.currentMemoryUsage, 0)
        XCTAssertNil(cache.get(conversation.id.uuidString))
    }

    // MARK: - LRU item-count cap

    func testItemCountCap_doesNotExceedMaxItems() {
        let maxItems = cache.maxCacheItems

        for _ in 0..<maxItems {
            cache.set(makeConversation(), messages: [])
        }
        XCTAssertEqual(cache.cacheItemCount, maxItems)

        // One more insert must evict rather than exceed the cap.
        cache.set(makeConversation(), messages: [])

        XCTAssertEqual(cache.cacheItemCount, maxItems)
    }
}
