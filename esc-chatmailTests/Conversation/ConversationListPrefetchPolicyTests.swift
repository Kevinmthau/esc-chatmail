import XCTest
import CoreData
@testable import esc_chatmail

/// F19: pins `ConversationListPrefetchPolicy.emailsToPrefetch` — the pure
/// decision behind the chat list's delta prefetch. The view model submits
/// only what this policy returns, so uniqueness, already-submitted
/// exclusion, order preservation, and the cap are the guarantees that keep
/// reloads from re-running the Contacts batch for warm rows.
///
/// Note: `ConversationSnapshot.participantEmails` is sorted per conversation,
/// so "window order" here means item order first, then each item's sorted
/// email order.
@MainActor
final class ConversationListPrefetchPolicyTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.viewContext
    }

    override func tearDown() {
        context = nil
        stack = nil
        super.tearDown()
    }

    // Revert-check: ConversationListPrefetchPolicy.emailsToPrefetch's
    // first-occurrence dedup — an email shared by two window rows must be
    // submitted once, at its first row's position.
    func testEmailsToPrefetch_duplicateEmailsAcrossItems_returnsUniqueInWindowOrder() throws {
        let first = try makeItem(emails: ["a@example.com", "b@example.com"], date: 300)
        let second = try makeItem(emails: ["b@example.com", "c@example.com"], date: 200)

        let emails = ConversationListPrefetchPolicy.emailsToPrefetch(
            newItems: [first, second],
            alreadySubmitted: [],
            limit: 10
        )

        XCTAssertEqual(emails, ["a@example.com", "b@example.com", "c@example.com"])
    }

    // Revert-check: ConversationListPrefetchPolicy.emailsToPrefetch's
    // alreadySubmitted exclusion — the delta contract: emails the view model
    // already handed to the prefetchers this window generation must not be
    // resubmitted.
    func testEmailsToPrefetch_alreadySubmittedEmails_areExcluded() throws {
        let first = try makeItem(emails: ["a@example.com", "b@example.com"], date: 300)
        let second = try makeItem(emails: ["c@example.com"], date: 200)

        let emails = ConversationListPrefetchPolicy.emailsToPrefetch(
            newItems: [first, second],
            alreadySubmitted: ["b@example.com"],
            limit: 10
        )

        XCTAssertEqual(emails, ["a@example.com", "c@example.com"])
    }

    // Revert-check: ConversationListPrefetchPolicy.emailsToPrefetch's cap —
    // the result must stop at `limit` emails, keeping the earliest rows'
    // emails (the thundering-herd bound the view model passes as
    // visibleItemCount + bufferSize).
    func testEmailsToPrefetch_moreEmailsThanLimit_capsAtLimitKeepingEarliest() throws {
        let first = try makeItem(emails: ["a@example.com", "b@example.com"], date: 300)
        let second = try makeItem(emails: ["c@example.com", "d@example.com"], date: 200)

        let emails = ConversationListPrefetchPolicy.emailsToPrefetch(
            newItems: [first, second],
            alreadySubmitted: [],
            limit: 3
        )

        XCTAssertEqual(emails, ["a@example.com", "b@example.com", "c@example.com"])
    }

    // Revert-check: ConversationListPrefetchPolicy.emailsToPrefetch — an
    // empty delta must produce an empty submission (the view model then
    // skips the detached prefetch task entirely).
    func testEmailsToPrefetch_noNewItemsOrFullySubmitted_returnsEmpty() throws {
        XCTAssertEqual(
            ConversationListPrefetchPolicy.emailsToPrefetch(
                newItems: [],
                alreadySubmitted: [],
                limit: 10
            ),
            []
        )

        let item = try makeItem(emails: ["a@example.com"], date: 300)
        XCTAssertEqual(
            ConversationListPrefetchPolicy.emailsToPrefetch(
                newItems: [item],
                alreadySubmitted: ["a@example.com"],
                limit: 10
            ),
            []
        )
    }

    // Revert-check: ConversationListPrefetchPolicy.emailsToPrefetch's
    // `limit > 0` guard — a non-positive cap must submit nothing.
    func testEmailsToPrefetch_nonPositiveLimit_returnsEmpty() throws {
        let item = try makeItem(emails: ["a@example.com"], date: 300)

        XCTAssertEqual(
            ConversationListPrefetchPolicy.emailsToPrefetch(
                newItems: [item],
                alreadySubmitted: [],
                limit: 0
            ),
            []
        )
    }

    // MARK: - Helpers

    private func makeItem(emails: [String], date: TimeInterval) throws -> ConversationListItem {
        let conversation = ConversationBuilder()
            .withDisplayName("conversation-\(UUID().uuidString)")
            .withSnippet("snippet")
            .visible()
            .withLastMessageDate(Date(timeIntervalSince1970: date))
            .build(in: context)

        for email in emails {
            let person = PersonBuilder()
                .withEmail(email)
                .withDisplayName(email)
                .build(in: context)
            let participant = context.insertTestObject(ConversationParticipant.self)
            participant.id = UUID()
            participant.participantRole = .normal
            participant.person = person
            participant.conversation = conversation
        }

        try stack.saveViewContext()
        return ConversationListItem(conversation: conversation)
    }
}
