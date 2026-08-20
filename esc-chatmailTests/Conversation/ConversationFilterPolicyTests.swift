import XCTest
@testable import esc_chatmail

/// F8: pins the per-filter facts centralized on `ConversationFilter`.
/// Each facet used to live as a switch at one of its call sites
/// (`ConversationFilterService`, `ConversationWindowProvider`,
/// `ConversationListViewModel`); these tests pin the enum's answers
/// case-for-case so a fifth filter must decide every facet explicitly.
final class ConversationFilterPolicyTests: XCTestCase {

    // MARK: - requiresContactCache

    // Revert-check: ConversationFilter.requiresContactCache — .all/.unread
    // must not trigger the lazy contact-cache load.
    func testRequiresContactCache_allAndUnread_doNotRequireCache() {
        XCTAssertFalse(ConversationFilter.all.requiresContactCache)
        XCTAssertFalse(ConversationFilter.unread.requiresContactCache)
    }

    // Revert-check: ConversationFilter.requiresContactCache — .contacts/.other
    // both evaluate contact membership, so both need the cache.
    func testRequiresContactCache_contactsAndOther_requireCache() {
        XCTAssertTrue(ConversationFilter.contacts.requiresContactCache)
        XCTAssertTrue(ConversationFilter.other.requiresContactCache)
    }

    // MARK: - needsInMemoryCandidateScan(hasSearchText:)

    // Revert-check: ConversationFilter.needsInMemoryCandidateScan(hasSearchText:)
    // — without search text the .all/.unread store predicate is exact, so a
    // plain fetchLimit fetch suffices.
    func testNeedsInMemoryCandidateScan_allAndUnreadWithoutSearchText_noScan() {
        XCTAssertFalse(ConversationFilter.all.needsInMemoryCandidateScan(hasSearchText: false))
        XCTAssertFalse(ConversationFilter.unread.needsInMemoryCandidateScan(hasSearchText: false))
    }

    // Revert-check: ConversationFilter.needsInMemoryCandidateScan(hasSearchText:)
    // — SQLite CONTAINS[cd] and Foundation diacritic-insensitive matching
    // disagree, so search must scan past SQL-visible candidates the in-memory
    // match rejects.
    func testNeedsInMemoryCandidateScan_allAndUnreadWithSearchText_scans() {
        XCTAssertTrue(ConversationFilter.all.needsInMemoryCandidateScan(hasSearchText: true))
        XCTAssertTrue(ConversationFilter.unread.needsInMemoryCandidateScan(hasSearchText: true))
    }

    // Revert-check: ConversationFilter.needsInMemoryCandidateScan(hasSearchText:)
    // — contact membership is not SQL-expressible, so .contacts/.other always
    // scan, search text or not.
    func testNeedsInMemoryCandidateScan_contactsAndOther_alwaysScan() {
        XCTAssertTrue(ConversationFilter.contacts.needsInMemoryCandidateScan(hasSearchText: false))
        XCTAssertTrue(ConversationFilter.contacts.needsInMemoryCandidateScan(hasSearchText: true))
        XCTAssertTrue(ConversationFilter.other.needsInMemoryCandidateScan(hasSearchText: false))
        XCTAssertTrue(ConversationFilter.other.needsInMemoryCandidateScan(hasSearchText: true))
    }

    // MARK: - canMatchAnything(hasContactEmails:)

    // Revert-check: ConversationFilter.canMatchAnything(hasContactEmails:) —
    // .all/.unread/.other can match regardless of the contact cache
    // (.other treats an empty cache as "everyone is other").
    func testCanMatchAnything_allUnreadOther_matchEvenWithEmptyCache() {
        XCTAssertTrue(ConversationFilter.all.canMatchAnything(hasContactEmails: false))
        XCTAssertTrue(ConversationFilter.unread.canMatchAnything(hasContactEmails: false))
        XCTAssertTrue(ConversationFilter.other.canMatchAnything(hasContactEmails: false))
    }

    // Revert-check: ConversationFilter.canMatchAnything(hasContactEmails:) —
    // .contacts with an empty cache can match nothing, which is what lets the
    // window provider skip the candidate scan entirely.
    func testCanMatchAnything_contactsWithEmptyCache_cannotMatch() {
        XCTAssertFalse(ConversationFilter.contacts.canMatchAnything(hasContactEmails: false))
    }

    // Revert-check: ConversationFilter.canMatchAnything(hasContactEmails:) —
    // a populated cache restores .contacts matching.
    func testCanMatchAnything_contactsWithPopulatedCache_canMatch() {
        XCTAssertTrue(ConversationFilter.contacts.canMatchAnything(hasContactEmails: true))
    }

    // MARK: - storePredicate

    // Revert-check: ConversationFilter.storePredicate — .unread contributes
    // the inboxUnreadCount > 0 clause the window provider appends.
    func testStorePredicate_unread_filtersOnInboxUnreadCount() throws {
        let predicate = try XCTUnwrap(ConversationFilter.unread.storePredicate)
        XCTAssertEqual(
            predicate.predicateFormat,
            NSPredicate(format: "inboxUnreadCount > 0").predicateFormat
        )
        XCTAssertTrue(predicate.evaluate(with: ["inboxUnreadCount": 3]))
        XCTAssertFalse(predicate.evaluate(with: ["inboxUnreadCount": 0]))
    }

    // Revert-check: ConversationFilter.storePredicate — .all/.contacts/.other
    // add no SQL clause (contact membership is filtered in memory).
    func testStorePredicate_allContactsOther_addNoClause() {
        XCTAssertNil(ConversationFilter.all.storePredicate)
        XCTAssertNil(ConversationFilter.contacts.storePredicate)
        XCTAssertNil(ConversationFilter.other.storePredicate)
    }
}
