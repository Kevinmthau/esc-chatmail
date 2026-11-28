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
    /// own and the model's (conversation, date) and, from model 8,
    /// (conversation, isUnread) fetch indexes.
    private static let conversationIndexes: Set<String> = [
        "ZMESSAGE_ZCONVERSATION_INDEX",
        "Z_Message_byConversationAndDateIndex",
        "Z_Message_byConversationAndUnreadIndex"
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
    /// Revert-check: model 8 dropped `byIsUnreadIndex`, so the predicate's
    /// spelling no longer reverts this. Putting that index back into the
    /// current model version and spelling the predicate `isUnread == YES`
    /// brings `SEARCH t0 USING INDEX Z_Message_byIsUnreadIndex` back.
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
            XCTAssertTrue(Self.isDrivenByTheConversation(plan), "\(statistics): \(plan)")
        }
    }

    // MARK: - Inbox rollup after a one-message change

    /// The three statements `MessageActions.applyInboxRollup` runs.
    private struct RollupPlans {
        let inboxCount: Plan
        let unreadCount: Plan
        let newestInbox: Plan
    }

    /// Picks the rollup's statements out of a recording by their SQL. The
    /// recording also holds the action's own faults and its save, and none of
    /// those is a count or sorts by date.
    ///
    /// A recording is of the whole process, so the INBOX count is asked for
    /// by its shape, not as "the count that is not the unread one": a count
    /// of messages joined to their labels, in one SELECT. A transcript
    /// page's count, which a task an earlier test left can add, reads the
    /// labels in a subquery, and is driven by the conversation whatever the
    /// rollup's count does.
    private func rollupPlans(in plans: [Plan], _ statistics: ScaleStoreTemplate.Statistics) throws -> RollupPlans {
        let messagePlans = plans.filter { $0.reads("ZMESSAGE") }
        let counts = messagePlans.filter { $0.sql.hasPrefix("SELECT COUNT(") }
        return RollupPlans(
            inboxCount: try XCTUnwrap(
                counts.first { !$0.sql.contains("ZISUNREAD") && Self.joinsLabelsInOneSelect($0) },
                "\(statistics):\n\(messagePlans)"
            ),
            unreadCount: try XCTUnwrap(
                counts.first { $0.sql.contains("ZISUNREAD") },
                "\(statistics):\n\(messagePlans)"
            ),
            newestInbox: try XCTUnwrap(
                messagePlans.first { $0.sql.contains("ORDER BY") && $0.sql.contains("ZINTERNALDATE") },
                "\(statistics):\n\(messagePlans)"
            )
        )
    }

    /// Whether the statement joins messages to their labels and has no
    /// subquery: the shape of `conversation == %@ AND ANY labels.id == %@`.
    private static func joinsLabelsInOneSelect(_ plan: Plan) -> Bool {
        plan.sql.contains("JOIN ZLABEL") && plan.sql.components(separatedBy: "SELECT").count == 2
    }

    private func assertDrivenByTheConversation(
        _ plan: Plan,
        _ statistics: ScaleStoreTemplate.Statistics,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(plan.scans(of: "ZMESSAGE"), [], "\(statistics): \(plan)", file: file, line: line)
        XCTAssertTrue(Self.isDrivenByTheConversation(plan), "\(statistics): \(plan)", file: file, line: line)
    }

    /// The newest INBOX message of the largest chat, on the view context
    /// `MessageActions` is handed, with how many INBOX messages the chat has.
    @MainActor
    private func newestInboxMessageOfLargestChat(
        _ manifest: ScaleStoreManifest,
        in context: NSManagedObjectContext
    ) throws -> (message: Message, conversation: Conversation, inboxCount: Int) {
        let conversationRequest = Conversation.fetchRequest()
        conversationRequest.predicate = ConversationPredicates.id(manifest.largestConversationID)
        let conversation = try XCTUnwrap(try context.fetch(conversationRequest).first)

        let request = Message.fetchRequest()
        request.predicate = NSPredicate(
            format: "conversation == %@ AND ANY labels.id == %@",
            conversation,
            "INBOX"
        )
        request.sortDescriptors = [NSSortDescriptor(key: "internalDate", ascending: false)]
        request.fetchLimit = 2
        let newest = try context.fetch(request)
        let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
        countRequest.predicate = request.predicate
        return (try XCTUnwrap(newest.first), conversation, try context.count(for: countRequest))
    }

    /// Review item `single-archive-rollup-materializes-inbox`. Archiving one
    /// message recomputes its conversation's rollup with two counts and a
    /// one-row fetch (`MessageActions.applyInboxRollup`), here in the
    /// largest chat of the store. Each of the three reaches ZMESSAGE only
    /// through an index on the conversation: none walks the table, the
    /// store-wide unread index or the store-wide date index, with or without
    /// statistics.
    ///
    /// Revert-check: with `conversation.id == %@` (the conversation's UUID)
    /// in place of `conversation == %@` in
    /// `MessageActions.storedInboxPredicate`, a store without statistics
    /// answers the INBOX count from the label (`SCAN t3`, then every INBOX
    /// membership in the mailbox) and the newest-INBOX fetch from a walk of
    /// the whole label join table (`SCAN t2`), reaching each message by its
    /// primary key. Under model 7, `isUnread == YES` in
    /// `MessagePredicates.unreadInInbox` drove the unread count from
    /// `Z_Message_byIsUnreadIndex`, which model 8 drops.
    @MainActor
    func testSingleMessageArchive_rollupCountsAndNewestInboxFetch_areDrivenByTheConversation() async throws {
        for statistics in Self.bothStatistics {
            let (stack, manifest) = try ScaleStoreTemplate.s2.makeStack(statistics: statistics)
            let actionsStack = MainQueueMessageActionsCoreDataStack(wrapping: stack)
            let pendingActions = MockPendingActionsManager()
            let actions = MessageActions(
                coreDataStack: actionsStack,
                pendingActionsManager: pendingActions,
                rollupMutationSerializer: ConversationRollupMutationSerializer(),
                syncRunCoordinator: SyncRunCoordinator()
            )
            let viewContext = actionsStack.viewContext
            let target = try newestInboxMessageOfLargestChat(manifest, in: viewContext)
            let archivedID = target.message.id
            XCTAssertGreaterThan(target.inboxCount, 1, "\(statistics)")

            let plans = try await SQLiteQueryPlanRecorder.record {
                await actions.archive(message: target.message)
            }

            // The archive happened, and the rollup it left is the store's.
            let queued = await pendingActions.queuedSingleActions
            XCTAssertEqual(queued.map(\.messageId), [archivedID], "\(statistics)")
            viewContext.refreshAllObjects()
            let after = try newestInboxMessageOfLargestChat(manifest, in: viewContext)
            XCTAssertEqual(after.inboxCount, target.inboxCount - 1, "\(statistics)")
            XCTAssertTrue(after.conversation.hasInbox, "\(statistics)")
            XCTAssertEqual(after.conversation.latestInboxDate, after.message.internalDate, "\(statistics)")

            let rollup = try rollupPlans(in: plans, statistics)
            assertDrivenByTheConversation(rollup.inboxCount, statistics)
            assertDrivenByTheConversation(rollup.unreadCount, statistics)
            assertDrivenByTheConversation(rollup.newestInbox, statistics)
        }
    }

    /// Marking a conversation unread finds its newest INBOX message with the
    /// same one-row fetch, with no message left out by ID
    /// (`MessageActions.fetchLatestStoredInboxMessage`), and then runs the
    /// rollup. The fetch is the conversation's, however large the chat.
    ///
    /// Revert-check: the UUID form in `MessageActions.storedInboxPredicate`,
    /// as in the test above, has a store without statistics walk the whole
    /// label join table for this fetch too.
    @MainActor
    func testMarkConversationAsUnread_newestInboxFetch_isDrivenByTheConversation() async throws {
        for statistics in Self.bothStatistics {
            let (stack, manifest) = try ScaleStoreTemplate.s2.makeStack(statistics: statistics)
            let actionsStack = MainQueueMessageActionsCoreDataStack(wrapping: stack)
            let pendingActions = MockPendingActionsManager()
            let actions = MessageActions(
                coreDataStack: actionsStack,
                pendingActionsManager: pendingActions,
                rollupMutationSerializer: ConversationRollupMutationSerializer(),
                syncRunCoordinator: SyncRunCoordinator()
            )
            let viewContext = actionsStack.viewContext
            let target = try newestInboxMessageOfLargestChat(manifest, in: viewContext)
            // The action marks the newest INBOX message unread only when it is read.
            if target.message.isUnread {
                target.message.isUnread = false
                try viewContext.save()
            }

            let plans = try await SQLiteQueryPlanRecorder.record {
                await actions.markConversationAsUnread(conversation: target.conversation)
            }

            let queued = await pendingActions.queuedSingleActions
            XCTAssertEqual(queued.map(\.messageId), [target.message.id], "\(statistics)")
            let newestInboxPlans = plans.filter {
                $0.reads("ZMESSAGE") && $0.sql.contains("ORDER BY") && $0.sql.contains("ZINTERNALDATE")
            }
            XCTAssertFalse(newestInboxPlans.isEmpty, "\(statistics):\n\(plans)")
            for plan in newestInboxPlans {
                assertDrivenByTheConversation(plan, statistics)
            }
        }
    }

    // MARK: - A conversation-wide action the store already has

    /// Review item `archive-spam-star-main-thread-viewcontext`, its repeat
    /// swipe. A conversation the store already has Report Spam applied to is
    /// left alone (`MessageActions.isAlreadyApplied`), and two counts decide
    /// that: its messages still in INBOX, and its messages without SPAM. A
    /// row is swiped a second time because it has not left the list yet,
    /// which is the large chat, so both counts are asked about here in the
    /// largest chat of the store. Each reaches ZMESSAGE only through an
    /// index on the conversation, with or without statistics.
    ///
    /// Revert-check: with `conversation.id == %@` (the conversation's UUID)
    /// in place of `conversation == %@` in the count of messages without
    /// SPAM in `MessageActions.isAlreadyApplied`, a store without
    /// statistics walks the whole message table for that count (`SCAN t0`),
    /// joining each message to its conversation. With statistics the plan
    /// stays the conversation's. The INBOX count is
    /// `MessageActions.storedInboxPredicate`, whose revert the rollup's test
    /// above names.
    @MainActor
    func testReportSpamConversation_reportedAgain_alreadyAppliedCounts_areDrivenByTheConversation() async throws {
        for statistics in Self.bothStatistics {
            let (stack, manifest) = try ScaleStoreTemplate.s2.makeStack(statistics: statistics)
            let actionsStack = MainQueueMessageActionsCoreDataStack(wrapping: stack)
            let pendingActions = MockPendingActionsManager()
            let actions = MessageActions(
                coreDataStack: actionsStack,
                pendingActionsManager: pendingActions,
                rollupMutationSerializer: ConversationRollupMutationSerializer(),
                syncRunCoordinator: SyncRunCoordinator()
            )
            let viewContext = actionsStack.viewContext
            // The seeded mailbox has no SPAM label, and without one the store
            // cannot say whether a report ran.
            _ = LabelBuilder().spam().build(in: viewContext)
            try viewContext.save()
            let conversationRequest = Conversation.fetchRequest()
            conversationRequest.predicate = ConversationPredicates.id(manifest.largestConversationID)
            let conversation = try XCTUnwrap(try viewContext.fetch(conversationRequest).first)

            await actions.reportSpamConversation(conversation: conversation)
            let queuedByTheFirst = await pendingActions.queuedConversationActions
            XCTAssertEqual(queuedByTheFirst.map { $0.type }, [.reportSpam], "\(statistics)")
            XCTAssertEqual(queuedByTheFirst.first?.messageIds.count, manifest.largestConversationMessageCount, "\(statistics)")

            let plans = try await SQLiteQueryPlanRecorder.record {
                await actions.reportSpamConversation(conversation: conversation)
            }

            // The second report found the store already had it, which is
            // both counts coming back zero: nothing more was queued.
            let queued = await pendingActions.queuedConversationActions
            XCTAssertEqual(queued.map { $0.type }, [.reportSpam], "\(statistics)")

            // By their SQL: the INBOX count joins the labels, and the count
            // of messages without SPAM reads them in a subquery.
            let counts = plans.filter { $0.reads("ZMESSAGE") && $0.sql.hasPrefix("SELECT COUNT(") }
            let inboxCount = try XCTUnwrap(
                counts.first { Self.joinsLabelsInOneSelect($0) },
                "\(statistics):\n\(counts)"
            )
            let withoutSpamCount = try XCTUnwrap(
                counts.first { $0.sql.contains("(SELECT COUNT(") },
                "\(statistics):\n\(counts)"
            )
            assertDrivenByTheConversation(inboxCount, statistics)
            assertDrivenByTheConversation(withoutSpamCount, statistics)
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
                window = try provider.fetchWindow(
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

    /// A Person change the list's rows can show is answered with one fetch of the window
    /// rows whose snapshots show the Person's address
    /// (`ConversationListChangeFetch.storedWindowConversations`), with their participants
    /// and persons prefetched for the snapshot build. Every read is by key: the rows by
    /// their primary key, the participants through their conversation index. The review
    /// asked for `ANY participants.person IN %@` in the predicate instead, and SQLite
    /// answered that from the participant table's person index, which for the user's own
    /// Person, in all 12,000 conversations of this store, read every one of its participant
    /// rows with or without statistics (measured 2026-11-28).
    ///
    /// HONEST SCOPE: no one line of production code reverts this, since the fetch has no
    /// participant term to put back. A predicate the primary key cannot serve, or a model
    /// version that drops the participant's conversation index, is what it would catch.
    @MainActor
    func testConversationListPersonChange_readsTheWindowRowsByKey() throws {
        for statistics in Self.bothStatistics {
            let (stack, _) = try ScaleStoreTemplate.s2.makeStack(statistics: statistics)
            let context = stack.makeMainQueueViewContext()
            let provider = ConversationWindowProvider()
            let window = try provider.fetchWindow(
                in: context,
                limit: provider.initialLimit,
                searchText: "",
                filter: .all,
                matchesVisibility: { _ in true }
            )
            XCTAssertEqual(window.count, provider.initialLimit, "\(statistics)")
            let windowIDs = window.map(\.objectID)
            context.reset()

            var matched: [Conversation] = []
            let plans = try SQLiteQueryPlanRecorder.record {
                matched = try context.fetch(
                    ConversationListChangeFetch.storedWindowConversations(withIDs: windowIDs)
                )
            }

            XCTAssertEqual(Set(matched.map(\.objectID)), Set(windowIDs), "\(statistics)")
            let rowsPlan = try XCTUnwrap(
                plans.first { $0.reads("ZCONVERSATION") && $0.sql.contains("carray") },
                "\(statistics):\n\(plans)"
            )
            XCTAssertEqual(rowsPlan.scans(of: "ZCONVERSATION"), [], "\(statistics): \(rowsPlan)")
            XCTAssertTrue(
                rowsPlan.steps.contains { $0.contains("INTEGER PRIMARY KEY") },
                "\(statistics): \(rowsPlan)"
            )
            let participantPlan = try XCTUnwrap(
                plans.first { $0.reads("ZCONVERSATIONPARTICIPANT") },
                "\(statistics):\n\(plans)"
            )
            XCTAssertEqual(participantPlan.scans(of: "ZCONVERSATIONPARTICIPANT"), [], "\(statistics): \(participantPlan)")
            XCTAssertEqual(
                participantPlan.indexes(on: "ZCONVERSATIONPARTICIPANT"),
                ["ZCONVERSATIONPARTICIPANT_ZCONVERSATION_INDEX"],
                "\(statistics): \(participantPlan)"
            )
            if let personPlan = plans.first(where: { $0.reads("ZPERSON") }) {
                XCTAssertEqual(personPlan.scans(of: "ZPERSON"), [], "\(statistics): \(personPlan)")
            }
        }
    }

    // MARK: - Message by Gmail ID

    /// Every message a sync persists is first looked up by its Gmail ID, and
    /// that lookup is a search of an index on `id`. Model 7 had two such
    /// indexes, the uniqueness constraint's and the duplicate `byIdIndex`;
    /// model 8 dropped the duplicate, and this is the test that must stay
    /// green for it.
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

    // MARK: - Stored rows of deleted messages

    /// Before a deleted message's body file is removed, the store is asked which of a
    /// chunk's 100 message IDs have a row again (`DeletedRowFileReclamation.liveMessageIDs`,
    /// scalability review step 7). It is asked under the HTML boundary's lock, once for
    /// each chunk of a purge, so it must be 100 searches of the index on `id` and never a
    /// walk of ZMESSAGE.
    ///
    /// HONEST SCOPE: no one line of production code reverts this. It fails if the fetch
    /// stops being an `IN` over `id`, or if a model version leaves `Message.id` with no
    /// index. The matching check for attachment files has no test here, because this
    /// store has no attachments: since model 8 it searches the two path indexes, which
    /// `ModelV8IndexPlanTests` pins on a small store.
    func testStoredRowCheckForDeletedBodies_searchesTheIndexOnTheMessageID() throws {
        for statistics in Self.bothStatistics {
            let (stack, _) = try ScaleStoreTemplate.s2.makeStack(statistics: statistics)
            let context = stack.newBackgroundContext()
            let stored = Set((0..<100).map { ScaleStoreSeeder.messageID(at: $0 * 1_000) })

            var live: Set<String> = []
            let plans = try SQLiteQueryPlanRecorder.record {
                live = try DeletedRowFileReclamation.liveMessageIDs(
                    among: stored.union(["never-stored"]),
                    in: context
                )
            }

            XCTAssertEqual(live, stored, "\(statistics)")
            let plan = try XCTUnwrap(plans.first { $0.reads("ZMESSAGE") }, "\(statistics):\n\(plans)")
            XCTAssertEqual(plan.scans(of: "ZMESSAGE"), [], "\(statistics): \(plan)")
            XCTAssertFalse(plan.indexes(on: "ZMESSAGE").isEmpty, "\(statistics): \(plan)")
        }
    }

    // MARK: - History-recovery repair

    /// The repair a history recovery owes reads one batch of stored rows per run, newest
    /// first, before a date (`HistoryRecoveryRepair.storedBatch`): 250 rows, then every row
    /// of the second the batch is cut at. Both must be a walk of the index on
    /// `internalDate`, never of ZMESSAGE.
    ///
    /// HONEST SCOPE: no one line of production code reverts this. It fails if either fetch
    /// stops being a range over `internalDate`, or a model version drops that index.
    func testHistoryRecoveryRepairBatch_walksTheInternalDateIndex() async throws {
        for statistics in Self.bothStatistics {
            let (stack, _) = try ScaleStoreTemplate.s2.makeStack(statistics: statistics)
            let context = stack.newBackgroundContext()

            var rowCount = 0
            let plans = try await SQLiteQueryPlanRecorder.record {
                rowCount = try await HistoryRecoveryRepair.storedBatch(before: Date(), in: context).rows.count
            }

            XCTAssertGreaterThanOrEqual(rowCount, HistoryRecoveryRepair.batchRowLimit, "\(statistics)")
            let messagePlans = plans.filter { $0.reads("ZMESSAGE") }
            XCTAssertFalse(messagePlans.isEmpty, "\(statistics):\n\(plans)")
            for plan in messagePlans {
                XCTAssertEqual(plan.scans(of: "ZMESSAGE"), [], "\(statistics): \(plan)")
            }
        }
    }
}
