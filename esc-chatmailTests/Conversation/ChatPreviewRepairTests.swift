import CoreData
import XCTest
@testable import esc_chatmail

/// Every fixture, save, and assertion goes through the suite's `viewContext`, a
/// main-queue context from `TestCoreDataStack.makeMainQueueViewContext()`,
/// never `stack.viewContext`, which is private-queue. These `@MainActor` test
/// bodies build, save, refresh, and read managed objects on that context
/// directly, which is on-queue only for a main-queue context. The chat preview
/// repair itself works in background contexts, which stay private-queue; the
/// coordinator's `storage.viewContext` gets the suite's context too. See that
/// helper for what the private-queue shape races.
///
/// HONEST SCOPE: no test here can reproduce that race on demand. With
/// `-com.apple.CoreData.ConcurrencyDebug 1` the old shape traps and this shape
/// runs clean.
@MainActor
final class ChatPreviewRepairTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!
    private var flags: InMemoryMigrationFlagStore!
    private var handler: HTMLContentHandler!
    private var directory: URL!
    private var syncWaiter: MockForegroundSyncEngine!
    private var accountWork: SyncRunCoordinator!
    private let html = "<div>Keep this reply.</div><div class=\"gmail_signature\">Best,<br>Alex<br>Manager<br>alex@example.com</div>"

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack(storeKind: .sqlite)
        viewContext = stack.makeMainQueueViewContext()
        flags = InMemoryMigrationFlagStore()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        handler = HTMLContentHandler(messagesDirectory: directory)
        syncWaiter = MockForegroundSyncEngine()
        accountWork = SyncRunCoordinator()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        handler = nil
        accountWork = nil
        syncWaiter = nil
        flags = nil
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    // Revert-check: received-only eligibility, derivation from local HTML only,
    // non-empty assignment, and limited ID-ordered batches. Rows without local
    // HTML are scanned (recovery stores HTML under the message ID alone) but
    // derive nothing, so their saved preview survives.
    func testBatchesRepairReceivedHTMLAndPreserveOtherMessages() async throws {
        let received = try message("001")
        received.isUnread = true
        let outgoing = try message("002")
        outgoing.isFromMe = true
        outgoing.subject = "Fwd: Original message"
        let plain = try message("003", storedHTML: false)
        let missing = try message("004", storedHTML: false)
        missing.bodyStorageURI = directory.appendingPathComponent("missing.html").absoluteString
        let last = try message("005")
        try viewContext.save()

        let repair = ChatPreviewRepair(htmlContentHandler: handler)
        let background = stack.newBackgroundContext()
        let first = try await repair.prepareBatch(in: background, after: nil, limit: 1)
        XCTAssertEqual(first.lastMessageID, "001")
        XCTAssertEqual(first.changedMessageIDs, ["001"])
        XCTAssertTrue(stack.saveIfNeeded(context: background))
        let second = try await repair.prepareBatch(in: background, after: first.lastMessageID, limit: 2)
        XCTAssertEqual(second.lastMessageID, "004")
        XCTAssertTrue(second.changedMessageIDs.isEmpty, "Neither row has local HTML to derive from")
        XCTAssertTrue(stack.saveIfNeeded(context: background))
        let third = try await repair.prepareBatch(in: background, after: second.lastMessageID, limit: 2)
        XCTAssertEqual(third.lastMessageID, "005")
        XCTAssertEqual(third.changedMessageIDs, ["005"])
        XCTAssertTrue(stack.saveIfNeeded(context: background))
        let drained = try await repair.prepareBatch(in: background, after: third.lastMessageID, limit: 2)
        XCTAssertTrue(drained.didDrain)

        viewContext.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        XCTAssertEqual(last.chatPreviewText, received.chatPreviewText)
        XCTAssertTrue(received.isUnread)
        XCTAssertEqual(handler.loadHTML(for: "001"), html)
        for preserved in [outgoing, plain, missing] {
            XCTAssertEqual(preserved.chatPreviewText, "Old preview")
        }
    }

    // Revert-check: CacheVersioning.chatPreviewDerivationVersion schedules F12
    // through the existing coordinator after the prior repair completed;
    // EmailDOMQuoteRemover's link evidence changes only the saved preview.
    func testF12VersionRepairsLabeledContactsWithoutChangingCanonicalHTML() async throws {
        let received = try message("001")
        let f12HTML = """
        <p>Keep this reply.</p><p>Best,</p><p>Jane Doe</p>
        <p><a href="mailto:jane@example.test">Email me</a></p>
        <p><a href="tel:+14155551212">Call the office</a></p>
        """
        let canonicalURL = try XCTUnwrap(handler.saveHTML(f12HTML, for: "001"))
        received.bodyStorageURI = canonicalURL.absoluteString
        let canonicalData = try Data(contentsOf: canonicalURL)
        try viewContext.save()
        flags.set(true, forKey: "chatPreviewRepair.2026-09-09-signature-cleanup-v1")

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        viewContext.refreshAllObjects()

        XCTAssertEqual(received.chatPreviewText, "Keep this reply.\n\nBest,\n\nJane Doe")
        XCTAssertEqual(received.bodyStorageURI, canonicalURL.absoluteString)
        XCTAssertEqual(handler.loadHTML(for: "001"), f12HTML)
        XCTAssertEqual(try Data(contentsOf: canonicalURL), canonicalData)
        let previousWaits = syncWaiter.waitForCurrentSyncToCompleteCalls
        repair.repairPersistedChatPreviews()
        XCTAssertEqual(syncWaiter.waitForCurrentSyncToCompleteCalls, previousWaits)
        withExtendedLifetime(repair) {}
    }

    // Revert-check: CacheVersioning.chatPreviewDerivationVersion "2026-09-17-signature-front-core-v1"
    // re-derives a preview the previous version already completed; the Front wrapper fix changes
    // only the saved preview, never the canonical HTML bytes.
    func testFrontCoreVersionRepairsVendorWrapperPreviewWithoutChangingCanonicalHTML() async throws {
        let received = try message("001")
        let canonicalURL = try XCTUnwrap(handler.saveHTML(FrontSignatureFixture.html, for: "001"))
        received.bodyStorageURI = canonicalURL.absoluteString
        received.chatPreviewText = FrontSignatureFixture.leakedChatText
        let canonicalData = try Data(contentsOf: canonicalURL)
        try viewContext.save()
        flags.set(true, forKey: "chatPreviewRepair.2026-09-10-repeated-signature-v1")

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        viewContext.refreshAllObjects()

        XCTAssertEqual(received.chatPreviewText, FrontSignatureFixture.expectedChatText)
        XCTAssertEqual(handler.loadHTML(for: "001"), FrontSignatureFixture.html)
        XCTAssertEqual(try Data(contentsOf: canonicalURL), canonicalData)
        withExtendedLifetime(repair) {}
    }

    func testRepeatedFooterVersionRepairsPreviouslyCompletedPreviewWithoutChangingSource() async throws {
        let received = try message("001")
        let source = RepeatedCorporateSignatureFixture.html()
        let canonicalURL = try XCTUnwrap(handler.saveHTML(source, for: "001"))
        received.bodyStorageURI = canonicalURL.absoluteString
        received.chatPreviewText = RepeatedCorporateSignatureFixture.plainText(includeHistory: false)
        let canonicalData = try Data(contentsOf: canonicalURL)
        try viewContext.save()
        flags.set(true, forKey: "chatPreviewRepair.2026-09-10-signature-contact-links-v1")

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        viewContext.refreshAllObjects()

        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        XCTAssertEqual(received.chatPreviewText, RepeatedCorporateSignatureFixture.expectedChatText)
        XCTAssertEqual(received.bodyStorageURI, canonicalURL.absoluteString)
        XCTAssertEqual(try Data(contentsOf: canonicalURL), canonicalData)
        withExtendedLifetime(repair) {}
    }

    // Revert-check: pending mutations preserve their conversation without stopping unrelated repairs.
    func testPendingSendDefersWithoutSkippingProtectedMessage() async throws {
        _ = try message("001")
        let protected = try message("002")
        let unrelated = try message("003")
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "pending-send"
        record.createdAt = Date()
        record.conversationId = protected.conversation?.id
        try viewContext.save()
        let repair = ChatPreviewRepair(htmlContentHandler: handler)
        let background = stack.newBackgroundContext()
        let first = try await repair.prepareBatch(in: background, after: nil)
        let protectedConversationID = try XCTUnwrap(protected.conversation?.id)
        XCTAssertEqual(first.deferredConversations.map(\.id), [protectedConversationID])
        XCTAssertFalse(first.didDrain)
        XCTAssertEqual(first.lastMessageID, "003")
        XCTAssertEqual(first.changedMessageIDs, ["001", "003"])
        XCTAssertTrue(stack.saveIfNeeded(context: background))
        viewContext.refreshAllObjects()
        XCTAssertEqual(protected.chatPreviewText, "Old preview")
        XCTAssertEqual(unrelated.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        viewContext.delete(record)
        try viewContext.save()

        let resumed = try await repair.prepareDeferredRetryBatch(
            in: stack.newBackgroundContext(),
            deferredConversations: first.deferredConversations,
            after: nil
        )
        XCTAssertEqual(resumed.retriedConversationIDs, [protectedConversationID])
        XCTAssertEqual(resumed.changedMessageIDs, ["002"])
        XCTAssertTrue(resumed.didDrain)
    }

    // Revert-check: `ChatPreviewRepair.retryScope` re-reading the pending set
    // (`.pending`) keeps a still-pending conversation deferred without deriving
    // its rows; a deferred conversation that no longer exists and left no
    // participant hash (`.gone`) leaves the list through `Checkpoint.advanced`.
    func testDeferredRetry_stillPendingConversationStaysDeferredAndVanishedConversationIsDropped() async throws {
        let protected = try message("002")
        let protectedConversationID = try XCTUnwrap(protected.conversation?.id)
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "retained-failed-send"
        record.createdAt = Date()
        record.conversationId = protectedConversationID
        try viewContext.save()

        let vanished = ChatPreviewRepair.DeferredConversation(id: UUID())
        let deferred = [
            ChatPreviewRepair.DeferredConversation(id: protectedConversationID),
            vanished
        ]
        let repair = ChatPreviewRepair(htmlContentHandler: handler)
        let batch = try await repair.prepareDeferredRetryBatch(
            in: stack.newBackgroundContext(),
            deferredConversations: deferred,
            after: nil
        )
        XCTAssertEqual(batch.phase, .deferredRetry)
        XCTAssertEqual(batch.retriedConversationIDs, [vanished.id])
        XCTAssertTrue(batch.changedMessageIDs.isEmpty)
        XCTAssertTrue(batch.didDrain)

        let checkpoint = ChatPreviewRepair.Checkpoint(
            deferredConversations: deferred,
            isMainScanComplete: true
        ).advanced(by: batch)
        XCTAssertEqual(checkpoint.deferredConversations.map(\.id), [protectedConversationID])
        XCTAssertFalse(checkpoint.isComplete)
        viewContext.refreshAllObjects()
        XCTAssertEqual(protected.chatPreviewText, "Old preview")
    }

    // Revert-check: the participant-hash branch of `ChatPreviewRepair.retryScope`.
    // A duplicate merge deletes a cleared deferred conversation and moves its
    // rows into a survivor with the same hash; without the branch the entry
    // reads as `.gone` and drops with the moved row still on the old preview.
    // The pending survivor case pins that the branch still honors pending sends.
    func testDeferredRetry_conversationMergedAway_rederivesSurvivorRowsThroughParticipantHash() async throws {
        let survivor = ConversationBuilder().withParticipantHash("p|alex@example.com").build(in: viewContext)
        let moved = MessageBuilder().withId("001").inConversation(survivor).build(in: viewContext)
        moved.chatPreviewText = "Old preview"
        moved.bodyStorageURI = try XCTUnwrap(handler.saveHTML(html, for: "001")).absoluteString
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "survivor-send"
        record.createdAt = Date()
        record.conversationId = survivor.id
        try viewContext.save()

        let mergedAway = ChatPreviewRepair.DeferredConversation(id: UUID(), participantHash: "p|alex@example.com")
        let repair = ChatPreviewRepair(htmlContentHandler: handler)
        let whileSurvivorPending = try await repair.prepareDeferredRetryBatch(
            in: stack.newBackgroundContext(),
            deferredConversations: [mergedAway],
            after: nil
        )
        XCTAssertTrue(whileSurvivorPending.retriedConversationIDs.isEmpty, "A pending survivor keeps the entry deferred")
        XCTAssertTrue(whileSurvivorPending.changedMessageIDs.isEmpty)

        viewContext.delete(record)
        try viewContext.save()
        let background = stack.newBackgroundContext()
        let cleared = try await repair.prepareDeferredRetryBatch(
            in: background,
            deferredConversations: [mergedAway],
            after: nil
        )
        XCTAssertEqual(cleared.retriedConversationIDs, [mergedAway.id])
        XCTAssertEqual(cleared.changedMessageIDs, ["001"])
        XCTAssertTrue(stack.saveIfNeeded(context: background))
        viewContext.refreshAllObjects()
        XCTAssertEqual(moved.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
    }

    // Revert-check: `prepareDeferredRetryBatch` counting only derived rows
    // against `limit`, and resuming inside a cleared conversation through
    // `RetryCursor.afterMessageID`. Charging the `.pending` conversation
    // against the derivation budget leaves room for only "007"; finishing a
    // conversation after one batch regardless of `messages.count < budget`
    // drops "009" un-derived. The pending conversation's fixed ID sorts it
    // first, so the sweep always meets it before the cleared one.
    func testDeferredRetry_stillPendingConversationsDoNotCountAgainstLimit_resumesInsideClearedConversation() async throws {
        let retained = ConversationBuilder()
            .withId(try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
            .build(in: viewContext)
        for index in 1...6 {
            let id = String(format: "%03d", index)
            let pending = MessageBuilder().withId(id).inConversation(retained).build(in: viewContext)
            pending.chatPreviewText = "Old preview"
            pending.bodyStorageURI = try XCTUnwrap(handler.saveHTML(html, for: id)).absoluteString
        }
        let cleared = ConversationBuilder()
            .withId(try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002")))
            .build(in: viewContext)
        for id in ["007", "008", "009"] {
            let row = MessageBuilder().withId(id).inConversation(cleared).build(in: viewContext)
            row.chatPreviewText = "Old preview"
            row.bodyStorageURI = try XCTUnwrap(handler.saveHTML(html, for: id)).absoluteString
        }
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "retained-failed-send"
        record.createdAt = Date()
        record.conversationId = retained.id
        try viewContext.save()

        let repair = ChatPreviewRepair(htmlContentHandler: handler)
        let deferred = [
            ChatPreviewRepair.DeferredConversation(id: retained.id),
            ChatPreviewRepair.DeferredConversation(id: cleared.id)
        ]
        let first = try await repair.prepareDeferredRetryBatch(
            in: stack.newBackgroundContext(),
            deferredConversations: deferred,
            after: nil,
            limit: 2
        )
        XCTAssertTrue(first.retriedConversationIDs.isEmpty)
        XCTAssertEqual(first.changedMessageIDs, ["007", "008"])
        XCTAssertEqual(
            first.retryCursor,
            ChatPreviewRepair.RetryCursor(conversationKey: cleared.id.uuidString, afterMessageID: "008")
        )
        XCTAssertFalse(first.didDrain)

        let second = try await repair.prepareDeferredRetryBatch(
            in: stack.newBackgroundContext(),
            deferredConversations: deferred,
            after: first.retryCursor,
            limit: 2
        )
        XCTAssertEqual(second.retriedConversationIDs, [cleared.id])
        XCTAssertEqual(second.changedMessageIDs, ["009"])
        XCTAssertTrue(second.didDrain)

        let checkpoint = ChatPreviewRepair.Checkpoint(deferredConversations: deferred, isMainScanComplete: true)
            .advanced(by: first)
            .advanced(by: second)
        XCTAssertEqual(checkpoint.deferredConversations.map(\.id), [retained.id])
    }

    // Revert-check: the `checkpoint != batchCheckpoint` guard in
    // `runChatPreviewPass`. Without it every sync completion rewrites the
    // whole deferred list while a send stays retained, even though the retry
    // sweep changed nothing.
    func testCoordinator_retainedSendRetryChangesNothing_doesNotRewriteCheckpoint() async throws {
        _ = try message("001")
        let protected = try message("002")
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "retained-failed-send"
        record.createdAt = Date()
        record.conversationId = protected.conversation?.id
        try viewContext.save()

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        let key = ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey
        let afterFirstRun = flags.string(forKey: key)
        XCTAssertEqual(
            ChatPreviewRepair.Checkpoint.decode(afterFirstRun).deferredConversations.map(\.id),
            [try XCTUnwrap(protected.conversation?.id)]
        )
        let writesAfterFirstRun = flags.stringWriteCount(forKey: key)

        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        XCTAssertEqual(flags.stringWriteCount(forKey: key), writesAfterFirstRun)
        XCTAssertEqual(flags.string(forKey: key), afterFirstRun)
        viewContext.refreshAllObjects()
        XCTAssertEqual(protected.chatPreviewText, "Old preview")
        withExtendedLifetime(repair) {}
    }

    // Revert-check: `Checkpoint.advanced(by:)` marking the main scan complete
    // and keeping deferred conversations. The old resume-at-first-deferred cursor
    // rescanned every later row on every run while a retained send existed,
    // which overwrites the sentinel preview below on the second run.
    func testCoordinator_retainedSend_completesMainScanThenRetriesOnlyDeferredRows() async throws {
        _ = try message("001")
        let protected = try message("002")
        let unrelated = try message("003")
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "retained-delivery-unknown-send"
        record.createdAt = Date()
        record.conversationId = protected.conversation?.id
        try viewContext.save()

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        let afterFirstRun = ChatPreviewRepair.Checkpoint.decode(
            flags.string(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey)
        )
        XCTAssertTrue(afterFirstRun.isMainScanComplete, "A retained send must not keep the main scan open")
        XCTAssertEqual(afterFirstRun.deferredConversations.map(\.id), [try XCTUnwrap(protected.conversation?.id)])
        XCTAssertNil(afterFirstRun.afterMessageID)
        XCTAssertNil(afterFirstRun.resumeAtMessageID)
        XCTAssertFalse(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))

        // A sentinel only a rescan would overwrite: 003 was already derived.
        viewContext.refreshAllObjects()
        unrelated.chatPreviewText = "Sentinel"
        try viewContext.save()

        // Sync completion re-runs the pass while the send is still retained.
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        viewContext.refreshAllObjects()
        XCTAssertEqual(unrelated.chatPreviewText, "Sentinel", "Later runs must retry only the deferred rows")
        XCTAssertEqual(protected.chatPreviewText, "Old preview")
        XCTAssertEqual(
            ChatPreviewRepair.Checkpoint.decode(
                flags.string(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey)
            ),
            afterFirstRun
        )

        // Once the record clears, the deferred row is derived and the pass latches.
        viewContext.delete(record)
        try viewContext.save()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        viewContext.refreshAllObjects()
        XCTAssertEqual(protected.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        XCTAssertEqual(unrelated.chatPreviewText, "Sentinel")
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        XCTAssertNil(flags.string(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey))
        withExtendedLifetime(repair) {}
    }

    // Revert-check: the legacy branch of `Checkpoint.advanced(by:)` and the
    // tolerant `Checkpoint.init(from:)`. A checkpoint written by the previous
    // build (scan cursor plus a first-deferred boundary, no deferred list)
    // finishes its scan, rescans from the boundary exactly once to learn which
    // rows were skipped, and then settles into deferred-only retries.
    func testCoordinator_legacyCheckpoint_rescansFromBoundaryOnceThenDefersByConversation() async throws {
        let beforeBoundary = try message("001")
        let protected = try message("002")
        let rescannedFromBoundary = try message("003")
        let afterCursor = try message("004")
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "retained-failed-send"
        record.createdAt = Date()
        record.conversationId = protected.conversation?.id
        try viewContext.save()
        flags.setString(
            #"{"afterMessageID":"003","firstDeferredMessageID":"002"}"#,
            forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey
        )

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        viewContext.refreshAllObjects()

        let checkpoint = ChatPreviewRepair.Checkpoint.decode(
            flags.string(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey)
        )
        XCTAssertTrue(checkpoint.isMainScanComplete)
        XCTAssertNil(checkpoint.firstDeferredMessageID, "The legacy boundary is consumed by one rescan")
        XCTAssertEqual(checkpoint.deferredConversations.map(\.id), [try XCTUnwrap(protected.conversation?.id)])
        XCTAssertEqual(beforeBoundary.chatPreviewText, "Old preview", "Rows before the legacy boundary are not rescanned")
        XCTAssertEqual(protected.chatPreviewText, "Old preview")
        XCTAssertEqual(rescannedFromBoundary.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        XCTAssertEqual(afterCursor.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        XCTAssertFalse(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        withExtendedLifetime(repair) {}
    }

    // Revert-check: deferred records must not starve later IDs or be lost when a sweep drains.
    func testCoordinatorRepairsUnrelatedRowsThenRetriesDeferredConversation() async throws {
        _ = try message("001")
        let protected = try message("002")
        let unrelated = try message("003")
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "retained-ambiguous-send"
        record.createdAt = Date()
        record.conversationId = protected.conversation?.id
        try viewContext.save()
        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        XCTAssertEqual(
            ChatPreviewRepair.Checkpoint.decode(flags.string(
                forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey
            )).deferredConversations.map(\.id),
            [try XCTUnwrap(protected.conversation?.id)]
        )
        viewContext.refreshAllObjects()
        XCTAssertEqual(protected.chatPreviewText, "Old preview")
        XCTAssertEqual(unrelated.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        XCTAssertFalse(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        viewContext.delete(record)
        try viewContext.save()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        viewContext.refreshAllObjects()
        XCTAssertEqual(protected.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        withExtendedLifetime(repair) {}
    }

    // Revert-check: `Checkpoint.normalized` keeping one entry per
    // conversation. A retained send in a long conversation used to persist
    // one message ID per deferred row, re-encoded after every main-scan batch;
    // the 60 deferred rows below are interleaved with 60 unrelated ones, so
    // every 25-row batch defers some, and without the dedupe the checkpoint
    // carries one entry per batch that deferred them.
    func testCoordinator_longDeferredConversation_persistsOneBoundedEntry() async throws {
        let retained = ConversationBuilder().build(in: viewContext)
        for index in 1...60 {
            let id = String(format: "%03d", index * 2)
            let row = MessageBuilder().withId(id).inConversation(retained).build(in: viewContext)
            row.chatPreviewText = "Old preview"
            _ = try message(String(format: "%03d", index * 2 + 1))
        }
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "retained-failed-send"
        record.createdAt = Date()
        record.conversationId = retained.id
        try viewContext.save()

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()

        let key = ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey
        let stored = try XCTUnwrap(flags.string(forKey: key))
        let checkpoint = ChatPreviewRepair.Checkpoint.decode(stored)
        XCTAssertTrue(checkpoint.isMainScanComplete)
        XCTAssertEqual(checkpoint.deferredConversations.map(\.id), [retained.id])
        XCTAssertFalse(stored.contains("deferredMessageIDs"), "No per-row message IDs are persisted")
        XCTAssertLessThan(stored.utf8.count, 200, "The checkpoint stays a few keys plus one entry")
        withExtendedLifetime(repair) {}
    }

    // Revert-check: the `legacyDeferredMessageIDs` branch of
    // `ChatPreviewRepair.prepareNextBatch` (and `Checkpoint.advanced`'s
    // `.legacyDeferredMigration` case). A checkpoint written by the per-row
    // build keeps its deferred rows: each maps to its current conversation,
    // the cleared one is re-derived, the pending one stays deferred, and the
    // per-row key is never written back. Without the branch the legacy list
    // is never consumed, so "003" keeps its old preview.
    func testCoordinator_perMessageLegacyCheckpoint_migratesToConversationsAndRederivesClearedRows() async throws {
        let protected = try message("002")
        let cleared = try message("003")
        let untouched = try message("004")
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "retained-failed-send"
        record.createdAt = Date()
        record.conversationId = protected.conversation?.id
        try viewContext.save()
        let key = ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey
        flags.setString(#"{"deferredMessageIDs":["002","003","999"],"isMainScanComplete":true}"#, forKey: key)

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        viewContext.refreshAllObjects()

        let stored = try XCTUnwrap(flags.string(forKey: key))
        let checkpoint = ChatPreviewRepair.Checkpoint.decode(stored)
        XCTAssertTrue(checkpoint.legacyDeferredMessageIDs.isEmpty)
        XCTAssertFalse(stored.contains("deferredMessageIDs"))
        XCTAssertTrue(checkpoint.isMainScanComplete)
        XCTAssertEqual(checkpoint.deferredConversations.map(\.id), [try XCTUnwrap(protected.conversation?.id)])
        XCTAssertEqual(protected.chatPreviewText, "Old preview")
        XCTAssertEqual(cleared.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        XCTAssertEqual(untouched.chatPreviewText, "Old preview", "Only deferred conversations are retried")
        XCTAssertFalse(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        withExtendedLifetime(repair) {}
    }

    // Revert-check: the `messages.count < budget` finish test in
    // `prepareDeferredRetryBatch`. A cleared conversation larger than one
    // 25-row batch is re-derived across batches in one run before it leaves
    // the list; finishing it after its first batch strands rows 026-030.
    func testCoordinator_clearedConversationLargerThanBatch_rederivesEveryRowThenLatches() async throws {
        let conversation = ConversationBuilder().build(in: viewContext)
        var rows: [Message] = []
        for index in 1...30 {
            let id = String(format: "%03d", index)
            let row = MessageBuilder().withId(id).inConversation(conversation).build(in: viewContext)
            row.chatPreviewText = "Old preview"
            row.bodyStorageURI = try XCTUnwrap(handler.saveHTML(html, for: id)).absoluteString
            rows.append(row)
        }
        try viewContext.save()
        flags.setString(
            ChatPreviewRepair.Checkpoint(
                deferredConversations: [ChatPreviewRepair.DeferredConversation(conversation)],
                isMainScanComplete: true
            ).encoded,
            forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey
        )

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        viewContext.refreshAllObjects()

        for row in rows {
            XCTAssertEqual(row.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex", "Row \(row.id)")
        }
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        XCTAssertNil(flags.string(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey))
        withExtendedLifetime(repair) {}
    }

    // Revert-check: empty derivations never replace a non-empty saved preview.
    func testEmptyHTMLPreservesSavedPreview() async throws {
        let empty = try message("001")
        empty.bodyStorageURI = try XCTUnwrap(handler.saveHTML("<div></div>", for: "001")).absoluteString
        try viewContext.save()
        let background = stack.newBackgroundContext()
        let batch = try await ChatPreviewRepair(htmlContentHandler: handler).prepareBatch(in: background, after: nil)
        XCTAssertTrue(batch.changedMessageIDs.isEmpty)
        XCTAssertEqual(batch.lastMessageID, "001")
        XCTAssertEqual(empty.chatPreviewText, "Old preview")
    }

    // Revert-check: checkpoints are only persisted after a successful save; failed work stays rerunnable.
    func testFailedSaveDoesNotAdvanceCursorAndNextCoordinatorResumes() async throws {
        let received = try message("001")
        try viewContext.save()
        var attemptedSave = false
        let failing = coordinator(save: { _ in attemptedSave = true; return false })
        failing.repairPersistedChatPreviews()
        await failing.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(attemptedSave)
        viewContext.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Old preview")
        XCTAssertNil(flags.string(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey))
        XCTAssertFalse(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))

        let resumed = coordinator()
        resumed.repairPersistedChatPreviews()
        await resumed.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        viewContext.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        XCTAssertNil(flags.string(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey))
        withExtendedLifetime((failing, resumed)) {}
    }

    // Revert-check: a persisted cursor survives coordinator recreation and completed versions are skipped.
    func testSavedCursorResumesAndCompletedVersionDoesNotRunAgain() async throws {
        let alreadyProcessed = try message("001")
        let next = try message("002")
        try viewContext.save()
        flags.setString(ChatPreviewRepair.Checkpoint(afterMessageID: "001").encoded,
                        forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey)
        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        viewContext.refreshAllObjects()
        XCTAssertEqual(alreadyProcessed.chatPreviewText, "Old preview")
        XCTAssertEqual(next.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        let previousWaits = syncWaiter.waitForCurrentSyncToCompleteCalls
        coordinator().repairPersistedChatPreviews()
        XCTAssertEqual(syncWaiter.waitForCurrentSyncToCompleteCalls, previousWaits)
        withExtendedLifetime(repair) {}
    }

    // Revert-check: a sync-idle signal cannot be lost before the repair starts waiting.
    func testRepairContinuesWhenSyncGateOpensBeforeWaitStarts() async throws {
        let received = try message("001")
        try viewContext.save()
        let gate = ChatPreviewRepairGate()
        syncWaiter.onWaitForCurrentSyncToComplete = { await gate.wait() }
        let repair = coordinator()

        await gate.open()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        viewContext.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")

        withExtendedLifetime(repair) {}
    }

    // Revert-check: a request captured before account teardown cannot acquire a lease in the next account.
    func testAccountTransitionWhileWaitingDoesNotWriteOrMarkCompletion() async throws {
        let received = try message("001")
        try viewContext.save()
        let gate = ChatPreviewRepairGate()
        syncWaiter.onWaitForCurrentSyncToComplete = { await gate.wait() }
        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await waitUntil { self.syncWaiter.waitForCurrentSyncToCompleteCalls == 1 }
        await accountWork.beginQuiescence()
        await accountWork.endQuiescence()
        await gate.open()
        // Join the original worker before checking account isolation so the
        // later retry cannot hide an unsafe write or completion marker.
        await repair.waitForChatPreviewRepairCompletion()
        viewContext.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Old preview")
        XCTAssertFalse(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        syncWaiter.onWaitForCurrentSyncToComplete = nil
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        viewContext.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        withExtendedLifetime(repair) {}
    }

    // Revert-check: `ChatPreviewRepair.backfilledPreview` — the forwarded-subject
    // guard, the received-without-HTML guard, and the outgoing body preference.
    // Each stored preview must equal the text the bubble already displayed, and
    // the bubble must not change after the backfill.
    func testBlankBackfillStoresTheTextTheBubbleAlreadyShows() async throws {
        let receivedIDOnlyHTML = try blankMessage("001", storedHTML: true, setsBodyStorageURI: false)
        let receivedWithoutHTML = try blankMessage("002", storedHTML: false)
        receivedWithoutHTML.bodyText = "Plain received body."
        let sentWithHTML = try blankMessage("003")
        sentWithHTML.isFromMe = true
        let sentWithoutHTML = try blankMessage("004", storedHTML: false)
        sentWithoutHTML.isFromMe = true
        sentWithoutHTML.bodyText = "Sent body text.\n\nThanks,\nMe"
        let sentRicherBody = try blankMessage("005", storedHTML: false)
        sentRicherBody.isFromMe = true
        sentRicherBody.bodyStorageURI = try XCTUnwrap(
            handler.saveHTML("<div>Short</div>", for: "005")
        ).absoluteString
        sentRicherBody.bodyText = "Short and then a much longer tail that the HTML lost."
        let forwarded = try blankMessage("006")
        forwarded.subject = "Fwd: Quarterly numbers"
        let whitespacePreview = try blankMessage("007")
        whitespacePreview.chatPreviewText = " \n "
        let newsletterFallbackBody = try blankMessage("008")
        newsletterFallbackBody.bodyText = """
        View in Browser
        https://example.com/view

        Unsubscribe
        https://example.com/unsubscribe
        """
        let trustedTransactionalSender = try blankMessage("009")
        trustedTransactionalSender.senderEmail = "noreply@members.ebay.com"
        try viewContext.save()

        let allFixtures = [
            receivedIDOnlyHTML, receivedWithoutHTML, sentWithHTML, sentWithoutHTML,
            sentRicherBody, forwarded, whitespacePreview, newsletterFallbackBody,
            trustedTransactionalSender
        ]
        var bubbleTextBefore: [String: String?] = [:]
        for message in allFixtures {
            bubbleTextBefore[message.id] = await bubbleText(for: message)
        }

        try await drainBackfill()
        viewContext.refreshAllObjects()

        // Filled: the stored preview is exactly what the bubble showed.
        for message in [receivedIDOnlyHTML, sentWithHTML, sentWithoutHTML, whitespacePreview] {
            let before = try XCTUnwrap(bubbleTextBefore[message.id] ?? nil, "Fixture \(message.id) had no bubble text")
            XCTAssertEqual(message.chatPreviewText, before, "Backfilled preview for \(message.id)")
        }
        // Revert-check: the richer-body comparison in `backfilledPreview`. The
        // loader no longer runs it, so this row is the one case where the
        // backfill stores something BETTER than the bubble showed — the fuller
        // authored body that nothing can recover once a preview is stored.
        XCTAssertEqual(
            sentRicherBody.chatPreviewText,
            "Short and then a much longer tail that the HTML lost.",
            "The backfill must migrate the richer authored body"
        )
        XCTAssertEqual(bubbleTextBefore[sentRicherBody.id] ?? nil, "Short", "Precondition: the loader alone derives only the HTML text")

        // Skipped: the loader still owns these rows.
        XCTAssertNil(receivedWithoutHTML.chatPreviewText, "Received rows without local HTML can still recover over the network")
        XCTAssertNil(forwarded.chatPreviewText, "A stored preview would replace the forwarded lead-in")
        XCTAssertNil(
            newsletterFallbackBody.chatPreviewText,
            "A newsletter-fallback body can still be replaced by recovered HTML"
        )
        XCTAssertNil(
            trustedTransactionalSender.chatPreviewText,
            "Trusted transactional senders can still recover HTML"
        )

        // The bubble is unchanged for every row, except the richer-body row,
        // whose bubble improves to the migrated text.
        for message in allFixtures where message.id != sentRicherBody.id {
            let after = await bubbleText(for: message)
            XCTAssertEqual(after, bubbleTextBefore[message.id] ?? nil, "Bubble text changed for \(message.id)")
        }
        let richerAfter = await bubbleText(for: sentRicherBody)
        XCTAssertEqual(richerAfter, "Short and then a much longer tail that the HTML lost.")
    }

    // Revert-check: `.receivedHTMLRederivation` must select every received row,
    // not just `bodyStorageURI` ones. Recovery stores HTML under the message ID
    // alone, and the backfill persists those rows' previews — so a derivation
    // change that skipped them would strand them on the old derivation forever.
    func testRederivationReachesReceivedRowsWithHTMLStoredByMessageIDOnly() async throws {
        let idOnlyHTML = try message("001", storedHTML: false)
        _ = try XCTUnwrap(handler.saveHTML(html, for: "001"))
        let plainTextOnly = try message("002", storedHTML: false)
        try viewContext.save()

        let background = stack.newBackgroundContext()
        let batch = try await ChatPreviewRepair(htmlContentHandler: handler).prepareBatch(in: background, after: nil)
        XCTAssertEqual(batch.changedMessageIDs, ["001"])
        XCTAssertTrue(stack.saveIfNeeded(context: background))

        viewContext.refreshAllObjects()
        XCTAssertEqual(idOnlyHTML.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        XCTAssertEqual(plainTextOnly.chatPreviewText, "Old preview", "No local HTML derives nothing")
    }

    // Revert-check: the per-pass loop in `repairPersistedChatPreviews` — a pass
    // that stops early must not block the next one. A retained failed send
    // defers its conversation indefinitely, so gating the backfill on the
    // re-derivation pass completing would strand every blank row.
    func testCoordinatorBackfillCompletesWhileRederivationDefers() async throws {
        let deferredByPendingSend = try message("001")
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "pending-send"
        record.createdAt = Date()
        record.conversationId = deferredByPendingSend.conversation?.id
        let blankSent = try blankMessage("002", storedHTML: false)
        blankSent.isFromMe = true
        blankSent.bodyText = "Sent body text."
        try viewContext.save()

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()

        viewContext.refreshAllObjects()
        XCTAssertFalse(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.blankChatPreviewBackfillMigrationKey))
        XCTAssertEqual(deferredByPendingSend.chatPreviewText, "Old preview")
        XCTAssertEqual(blankSent.chatPreviewText, "Sent body text.")
        withExtendedLifetime(repair) {}
    }

    // Revert-check: the backfill runs under the same pending-send deferral as
    // the re-derivation pass, so an in-flight send's conversation is untouched
    // and the pass stays incomplete until the record clears.
    func testBlankBackfillDefersPendingSendConversations() async throws {
        let blank = try blankMessage("001", storedHTML: false)
        blank.isFromMe = true
        blank.bodyText = "Sent body text."
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "pending-send"
        record.createdAt = Date()
        record.conversationId = blank.conversation?.id
        try viewContext.save()

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()

        viewContext.refreshAllObjects()
        XCTAssertNil(blank.chatPreviewText)
        XCTAssertFalse(flags.bool(forKey: ConversationLaunchRepairCoordinator.blankChatPreviewBackfillMigrationKey))
        withExtendedLifetime(repair) {}
    }

    private func drainBackfill() async throws {
        let repair = ChatPreviewRepair(htmlContentHandler: handler, pass: .blankPreviewBackfill)
        let background = stack.newBackgroundContext()
        var cursor: String?
        while true {
            let batch = try await repair.prepareBatch(in: background, after: cursor)
            XCTAssertTrue(stack.saveIfNeeded(context: background))
            if batch.didDrain { return }
            cursor = batch.lastMessageID
        }
    }

    private func bubbleText(for message: Message) async -> String? {
        let recovery = NoHTMLRecoverer()
        let loader = MessageBubbleLoader(
            contactsResolver: NoContactsResolver(),
            htmlContentHandler: handler,
            htmlContentLoader: HTMLContentLoader(contentHandler: handler, recoveryService: recovery),
            htmlContentRecoveryService: recovery,
            htmlAnalysisCache: MessageBubbleHTMLAnalysisCache(),
            renderedMessageCache: RenderedMessageCache()
        )
        let request = ChatMessageRowModelMapper.map(message).makeContentRequest()
        return await loader.loadContent(from: request).fullTextContent
    }

    private func blankMessage(
        _ id: String,
        storedHTML: Bool = true,
        setsBodyStorageURI: Bool = true
    ) throws -> Message {
        let message = try self.message(id, storedHTML: false)
        message.chatPreviewText = nil
        if storedHTML {
            let url = try XCTUnwrap(handler.saveHTML(html, for: id))
            if setsBodyStorageURI {
                message.bodyStorageURI = url.absoluteString
            }
        }
        return message
    }

    private func message(_ id: String, storedHTML: Bool = true) throws -> Message {
        let conversation = ConversationBuilder().build(in: viewContext)
        let message = MessageBuilder().withId(id).inConversation(conversation).build(in: viewContext)
        message.chatPreviewText = "Old preview"
        if storedHTML { message.bodyStorageURI = try XCTUnwrap(handler.saveHTML(html, for: id)).absoluteString }
        return message
    }

    private func coordinator(save: ((NSManagedObjectContext) -> Bool)? = nil) -> ConversationLaunchRepairCoordinator {
        let stack = self.stack!
        return ConversationLaunchRepairCoordinator(
            storage: StorageDependencies(
                viewContext: viewContext,
                makeBackgroundContext: { stack.newBackgroundContext() },
                saveIfNeeded: save ?? { stack.saveIfNeeded(context: $0) },
                migrationFlags: flags,
                personCache: Dependencies.shared.personCache,
                profilePhotoResolver: Dependencies.shared.profilePhotoResolver
            ),
            conversationManager: ConversationManager(currentUserEmail: { "me@example.com" }),
            syncWaiter: syncWaiter,
            notificationCenter: NotificationCenter(),
            conversationMutationSerializer: ConversationRollupMutationSerializer(),
            accountWorkCoordinator: accountWork,
            htmlContentHandler: handler,
            // Inherit the test's priority: see repairTaskPriority's doc.
            repairTaskPriority: nil
        )
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(60)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(condition(), "Repair did not reach the expected state", file: file, line: line)
    }
}

/// Remembers sync becoming idle so a worker arriving after `open()` cannot miss it.
private actor ChatPreviewRepairGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct NoHTMLRecoverer: HTMLContentRecovering {
    func recoverHTMLContent(messageId: String) async -> String? { nil }
}

private final class NoContactsResolver: ContactsResolving, @unchecked Sendable {
    func ensureAuthorization() async throws {}
    func lookup(email: String) async -> ContactMatch? { nil }
    func prewarm(emails: [String]) async {}
}
