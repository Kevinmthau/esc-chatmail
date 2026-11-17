import XCTest
import CoreData
@testable import esc_chatmail

/// The plans SQLite gives the app's hot fetches on a mailbox of S2 size
/// (`ScaleStoreShape.s2`: 120k messages in 12k conversations). Part of the
/// scale harness (`docs/scalability-review.md`, step 4 of "Suggested order");
/// it runs only under `./Scripts/codex-test.sh --performance`.
///
/// Each test calls the production code that builds the fetch, records what
/// SQLite planned for it (`SQLiteQueryPlanRecorder`), and asserts on the
/// plan's shape: which table is walked from one end, which index is used. No
/// test asserts a time. A plan is decided by the schema and, where the store
/// has them, by SQLite's statistics, so each fetch is asked about in both
/// states (`ScaleStoreTemplate.Statistics`): a store has no statistics until
/// its daily background ANALYZE has run, which on a new install, after a
/// store reset, or on a device that starves background tasks is "not yet".
///
/// KNOWN GAPS. Where today's plan is the one the review calls a defect, the
/// assertion that says so is wrapped in `XCTExpectFailure`, naming the review
/// item and the plan measured. `XCTExpectFailure` is strict: once the fix
/// lands the assertion passes, the test fails with "no failure was recorded",
/// and the wrapper comes off in that fix's own change, which gives the
/// assertion its `Revert-check:`. No assertion in this suite is wrapped
/// today: the transcript's and the unread snapshot's came off with the
/// objectID predicates (review step 5). `ScaleHubFaultTests` still has some.
///
/// What keeps a broken recorder from passing for a good plan: every test
/// unwraps the plan it is about, and checks what the fetch returned, before
/// it asserts on the plan.
final class ScaleQueryPlanTests: XCTestCase {
    private typealias Plan = SQLiteQueryPlanRecorder.Plan

    private static let bothStatistics: [ScaleStoreTemplate.Statistics] = [.none, .analyzed]

    // MARK: - Chat transcript

    /// The newest page of the largest chat and the count that goes with it,
    /// as `VirtualScrollState.loadMessagePage` fetches them.
    private func transcriptPlans(
        statistics: ScaleStoreTemplate.Statistics
    ) async throws -> (page: Plan, count: Plan) {
        let (stack, manifest) = try ScaleStoreTemplate.s2.makeStack(statistics: statistics)
        let context = stack.newBackgroundContext()
        let total = manifest.largestConversationMessageCount

        var loaded: VirtualScrollMessagePage?
        let plans = try await SQLiteQueryPlanRecorder.record {
            loaded = await VirtualScrollState.loadMessagePage(
                conversationId: manifest.largestConversationID.uuidString,
                range: (total - 60)..<total,
                in: context
            )
        }

        let page = try XCTUnwrap(loaded)
        XCTAssertNil(page.fetchErrorDescription)
        XCTAssertEqual(page.messageIDs.count, 60)
        XCTAssertEqual(page.totalCount, total)

        let messagePlans = plans.filter { $0.reads("ZMESSAGE") }
        XCTAssertEqual(messagePlans.count, 2, "Expected the page and its count:\n\(messagePlans)")
        let countPlan = try XCTUnwrap(messagePlans.first { $0.sql.hasPrefix("SELECT COUNT(") })
        let pagePlan = try XCTUnwrap(messagePlans.first { !$0.sql.hasPrefix("SELECT COUNT(") })
        return (pagePlan, countPlan)
    }

    /// Review item `chat-transcript-uuid-join-offset-paging`. The transcript
    /// used to filter on `conversation.id`, a join to an unindexed UUID, and
    /// with no statistics SQLite answered the page by walking every message
    /// in date order (`SCAN t0 USING INDEX Z_Message_byInternalDateIndex`)
    /// and the count by reading the whole table (`SCAN t0`). The page loader
    /// now looks the conversation up once and asks for its messages by
    /// objectID, which SQLite answers from the conversation's own index.
    ///
    /// Revert-check: returning `MessagePredicates.visibleInChat(conversationId:)`
    /// for a saved conversation from `VirtualScrollState.transcriptPredicate`,
    /// in place of `visibleInChat(conversationObjectID:)`, brings both scans
    /// back.
    func testTranscriptPageAndCount_withoutStatistics_walkNoMessagesOutsideTheChat() async throws {
        let plans = try await transcriptPlans(statistics: .none)

        XCTAssertEqual(plans.page.scans(of: "ZMESSAGE"), [], "\(plans.page)")
        XCTAssertEqual(plans.count.scans(of: "ZMESSAGE"), [], "\(plans.count)")
        XCTAssertTrue(Self.isDrivenByTheConversation(plans.page), "\(plans.page)")
        XCTAssertTrue(Self.isDrivenByTheConversation(plans.count), "\(plans.count)")
    }

    /// With statistics the plan is the same: the conversation's messages,
    /// found through an index on the conversation, and no other message.
    ///
    /// Revert-check: none of its own. With statistics the UUID join this
    /// replaced also read only the chat's messages
    /// (`SEARCH t0 USING INDEX ZMESSAGE_ZCONVERSATION_INDEX`, after a walk of
    /// ZCONVERSATION), so this is the test that must stay green when the
    /// model's indexes change.
    func testTranscriptPageAndCount_withStatistics_walkNoMessagesOutsideTheChat() async throws {
        let plans = try await transcriptPlans(statistics: .analyzed)

        XCTAssertEqual(plans.page.scans(of: "ZMESSAGE"), [], "\(plans.page)")
        XCTAssertEqual(plans.count.scans(of: "ZMESSAGE"), [], "\(plans.count)")
        XCTAssertTrue(Self.isDrivenByTheConversation(plans.page), "\(plans.page)")
        XCTAssertTrue(Self.isDrivenByTheConversation(plans.count), "\(plans.count)")
    }

    /// The indexes that find a conversation's messages: the relationship's
    /// own and the model's (conversation, date) fetch index.
    private static let conversationIndexes: Set<String> = [
        "ZMESSAGE_ZCONVERSATION_INDEX",
        "Z_Message_byConversationAndDateIndex"
    ]

    /// Whether the plan reaches ZMESSAGE through an index on the
    /// conversation and through no other index.
    private static func isDrivenByTheConversation(_ plan: Plan) -> Bool {
        let indexes = Set(plan.indexes(on: "ZMESSAGE"))
        return !indexes.isEmpty && indexes.isSubset(of: conversationIndexes)
    }

    // MARK: - Unread snapshot at chat open

    /// Review item `chat-open-unread-snapshot`. Opening a chat snapshots its
    /// unread INBOX messages (`MessageActions.snapshotUnreadInboxMessageObjectIDs`).
    /// SQLite used to drive that from the store-wide unread index, with or
    /// without statistics: it probed every unread message in the mailbox
    /// (26,408 in this store) to find the one in this chat. It is now driven
    /// by the conversation.
    ///
    /// Revert-check: `isUnread == YES` in place of `isUnread != NO` in
    /// `MessagePredicates.unreadInInbox` brings
    /// `SEARCH t0 USING INDEX Z_Message_byIsUnreadIndex` back.
    @MainActor
    func testUnreadSnapshot_isNotDrivenByTheMailboxWideUnreadIndex() async throws {
        for statistics in Self.bothStatistics {
            let (stack, manifest) = try ScaleStoreTemplate.s2.makeStack(statistics: statistics)
            let actions = MessageActions(
                coreDataStack: MainQueueMessageActionsCoreDataStack(wrapping: stack),
                pendingActionsManager: MockPendingActionsManager(),
                rollupMutationSerializer: ConversationRollupMutationSerializer(),
                syncRunCoordinator: SyncRunCoordinator()
            )
            let lookupContext = stack.newBackgroundContext()
            let conversationID = try await lookupContext.perform {
                let request = NSFetchRequest<NSManagedObjectID>(entityName: "Conversation")
                request.predicate = ConversationPredicates.id(manifest.ordinaryConversationID)
                request.resultType = .managedObjectIDResultType
                return try XCTUnwrap(try lookupContext.fetch(request).first)
            }

            var snapshot: [NSManagedObjectID] = []
            let plans = try await SQLiteQueryPlanRecorder.record {
                snapshot = await actions.snapshotUnreadInboxMessageObjectIDs(
                    conversationID: conversationID
                )
            }

            XCTAssertEqual(snapshot.count, manifest.ordinaryConversationUnreadCount, "\(statistics)")
            let messagePlans = plans.filter { $0.reads("ZMESSAGE") }
            XCTAssertEqual(messagePlans.count, 1, "\(statistics):\n\(messagePlans)")
            let plan = try XCTUnwrap(messagePlans.first)
            XCTAssertEqual(plan.scans(of: "ZMESSAGE"), [], "\(statistics): \(plan)")
            XCTAssertFalse(
                plan.indexes(on: "ZMESSAGE").contains("Z_Message_byIsUnreadIndex"),
                "\(statistics): \(plan)"
            )
            XCTAssertTrue(Self.isDrivenByTheConversation(plan), "\(statistics): \(plan)")
        }
    }

    // MARK: - Conversation list

    /// The first window of the conversation list
    /// (`ConversationWindowProvider.fetchWindow`) finds the unarchived
    /// conversations through an index and never reads ZCONVERSATION from one
    /// end. It does sort all of them in a temporary B-tree for each window
    /// (`USE TEMP B-TREE FOR ORDER BY`), which is the list's keyset-paging
    /// item in the review and is not asserted here.
    ///
    /// HONEST SCOPE: no one line of production code reverts this. A predicate
    /// the archive index cannot serve, or a model version that drops that
    /// index, is what it would catch.
    @MainActor
    func testConversationListWindow_findsUnarchivedConversationsThroughAnIndex() throws {
        for statistics in Self.bothStatistics {
            let (stack, _) = try ScaleStoreTemplate.s2.makeStack(statistics: statistics)
            let context = stack.makeMainQueueViewContext()
            let provider = ConversationWindowProvider()

            var window: [Conversation] = []
            let plans = try SQLiteQueryPlanRecorder.record {
                window = provider.fetchWindow(
                    in: context,
                    limit: provider.initialLimit,
                    searchText: "",
                    filter: .all,
                    matchesVisibility: { _ in true }
                )
            }

            XCTAssertEqual(window.count, provider.initialLimit, "\(statistics)")
            let windowPlan = try XCTUnwrap(
                plans.first { $0.reads("ZCONVERSATION") && $0.sql.contains("ORDER BY") },
                "\(statistics):\n\(plans)"
            )
            XCTAssertEqual(windowPlan.scans(of: "ZCONVERSATION"), [], "\(statistics): \(windowPlan)")
            XCTAssertFalse(windowPlan.indexes(on: "ZCONVERSATION").isEmpty, "\(statistics): \(windowPlan)")
        }
    }

    // MARK: - Message by Gmail ID

    /// Every message a sync persists is first looked up by its Gmail ID, and
    /// that lookup is a search of an index on `id`. The model has two such
    /// indexes today, the uniqueness constraint's and the duplicate
    /// `byIdIndex` the review wants dropped; this is the test that must stay
    /// green when one of them goes.
    ///
    /// HONEST SCOPE: no one line of production code reverts this. It fails if
    /// a model version leaves `Message.id` with no index at all.
    func testMessageLookupByGmailID_searchesAnIndex() throws {
        for statistics in Self.bothStatistics {
            let (stack, _) = try ScaleStoreTemplate.s2.makeStack(statistics: statistics)
            let context = stack.newBackgroundContext()
            let messageID = ScaleStoreSeeder.messageID(at: 77)

            var found: [String] = []
            let plans = try SQLiteQueryPlanRecorder.record {
                found = try context.performAndWait {
                    let request = NSFetchRequest<Message>(entityName: "Message")
                    request.predicate = MessagePredicates.id(messageID)
                    request.fetchLimit = 1
                    return try context.fetch(request).map(\.id)
                }
            }

            XCTAssertEqual(found, [messageID], "\(statistics)")
            let plan = try XCTUnwrap(plans.first { $0.reads("ZMESSAGE") }, "\(statistics):\n\(plans)")
            XCTAssertEqual(plan.scans(of: "ZMESSAGE"), [], "\(statistics): \(plan)")
            XCTAssertFalse(plan.indexes(on: "ZMESSAGE").isEmpty, "\(statistics): \(plan)")
        }
    }
}
