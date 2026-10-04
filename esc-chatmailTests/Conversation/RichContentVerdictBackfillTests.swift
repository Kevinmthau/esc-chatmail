import CoreData
import XCTest
@testable import esc_chatmail

/// Covers the launch backfill of `Message.richContentVerdict`: the batch scan in
/// `RichContentVerdictBackfill.prepareBatch`, and the pass
/// `ConversationLaunchRepairCoordinator.backfillRichContentVerdicts` drives around it (account
/// work lease, save, cursor, completion latch).
///
/// Fixtures are built and saved through the suite's `viewContext`, a main-queue context from
/// `TestCoreDataStack.makeMainQueueViewContext()`, never `stack.viewContext`, which is
/// private-queue: these `@MainActor` bodies touch it directly, and the coordinator's
/// `storage.viewContext` gets the same one. Assertions read the store through a fresh
/// background context (`storedVerdicts()`), so they see what was committed rather than what
/// this suite's registered objects hold.
@MainActor
final class RichContentVerdictBackfillTests: XCTestCase {
    private typealias Batch = RichContentVerdictBackfill.Batch

    private var stack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!
    private var flags: InMemoryMigrationFlagStore!
    private var handler: HTMLContentHandler!
    private var directory: URL!
    private var notificationCenter: NotificationCenter!
    private var syncWaiter: MockForegroundSyncEngine!
    private var accountWork: SyncRunCoordinator!
    private var saveSeam: VerdictBackfillSaveSeam!

    /// Classifies as rich: `<section>` is one of `RichContentClassifier`'s always-rich signals.
    private let richHTML = """
        <html><body><section><table role="presentation" width="100%">
        <tr><td><h1>Statement ready</h1></td></tr>
        <tr><td><p>Your monthly account statement is now available.</p></td></tr>
        <tr><td><a href="https://example.com/review">Review statement</a></td></tr>
        </table></section></body></html>
        """
    /// Classifies as text: short div-wrapped copy with no rich signal.
    private let plainHTML = "<div>See you at noon.</div>"

    private var migrationKey: String {
        ConversationLaunchRepairCoordinator.richContentVerdictBackfillMigrationKey
    }

    private var cursorKey: String {
        ConversationLaunchRepairCoordinator.richContentVerdictBackfillCursorKey
    }

    private var batchSize: Int {
        ConversationLaunchRepairCoordinator.richContentVerdictBackfillBatchSize
    }

    override func setUp() {
        super.setUp()
        // SQLite: the store-trump test needs the production store's optimistic locking, and
        // the scan's string ID ordering should be SQLite's.
        stack = TestCoreDataStack(storeKind: .sqlite)
        viewContext = stack.makeMainQueueViewContext()
        flags = InMemoryMigrationFlagStore()
        // A directory of its own: the account boundary is keyed by directory, so closing it
        // here cannot close the shared Messages directory other suites read.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RichContentVerdictBackfillTests-\(UUID().uuidString)")
        handler = HTMLContentHandler(messagesDirectory: directory)
        // Private center: production posts .syncCompleted on .default.
        notificationCenter = NotificationCenter()
        syncWaiter = MockForegroundSyncEngine()
        accountWork = SyncRunCoordinator()
        saveSeam = VerdictBackfillSaveSeam(stack: stack)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        saveSeam = nil
        accountWork = nil
        syncWaiter = nil
        notificationCenter = nil
        handler = nil
        directory = nil
        flags = nil
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    // HONEST SCOPE: guards this suite's fixtures, not production. Every "rich" and "not rich"
    // expectation below assumes these two classifications, so a classifier change that moves
    // either one fails here first, by name.
    func testFixtureHTML_classifiesAsRichAndAsText() {
        XCTAssertTrue(RichContentClassifier.hasGenuineRichContentAfterCleanup(richHTML))
        XCTAssertFalse(RichContentClassifier.hasGenuineRichContentAfterCleanup(plainHTML))
    }

    // MARK: - RichContentVerdictBackfill.prepareBatch

    // Revert-check: `message.storedRichContentVerdict = verdict` in
    // `RichContentVerdictBackfill.prepareBatch` (nothing is stamped without it), and the
    // `isFromMe == NO` predicate there (without it the own row is examined, stamped not rich,
    // and counted).
    func testPrepareBatch_unknownReceivedRows_stampsEachByItsStoredHTMLAndLeavesOwnRowsAlone() async throws {
        try row("004", html: richHTML, fromMe: true)
        try row("003", html: richHTML)
        try row("002", html: plainHTML)
        try row("001")
        try viewContext.save()

        let background = stack.newBackgroundContext()
        let batch = try await makeBackfill().prepareBatch(in: background, before: nil, limit: 10)

        XCTAssertEqual(batch, Batch(lastMessageID: "001", stampedCount: 3, didDrain: true))
        XCTAssertTrue(stack.saveIfNeeded(context: background))
        let stored = try await storedVerdicts()
        let expected: [String: RichContentVerdict] = [
            "004": .unknown,
            "003": .rich,
            "002": .notRich,
            "001": .notRich
        ]
        XCTAssertEqual(stored, expected)
    }

    // Revert-check: the `message.storedRichContentVerdict == .unknown` test in
    // `RichContentVerdictBackfill.prepareBatch` (without it "004" and "003" are re-stamped to
    // what their HTML classifies as; the persister and the refresher own current-epoch
    // stamps), and the `storedValue / 2 == epoch` test in
    // `RichContentVerdict.init(storedValue:epoch:)` (decoding any epoch leaves "002" holding
    // another epoch's answer as a known one).
    func testPrepareBatch_currentEpochStampIsLeftAsIs_otherEpochAndInvalidValuesAreRestamped() async throws {
        let otherEpochNotRich = RichContentVerdict.notRich.storedValue(
            epoch: CacheVersioning.richContentVerdictEpoch + 1
        )
        XCTAssertEqual(
            RichContentVerdict(storedValue: otherEpochNotRich), .unknown,
            "Precondition: a value stamped under another epoch reads as unknown"
        )
        XCTAssertEqual(
            RichContentVerdict(storedValue: 1), .unknown,
            "Precondition: 1 is a value no epoch produces"
        )

        // Both current-epoch stamps are deliberately the opposite of what the row's HTML
        // classifies as, so a re-stamp is visible.
        let stampedNotRich = try row("004", html: richHTML)
        stampedNotRich.storedRichContentVerdict = .notRich
        let stampedRich = try row("003", html: plainHTML)
        stampedRich.storedRichContentVerdict = .rich
        let otherEpoch = try row("002", html: richHTML)
        otherEpoch.richContentVerdict = otherEpochNotRich
        let invalidValue = try row("001", html: plainHTML)
        invalidValue.richContentVerdict = 1
        try viewContext.save()

        let background = stack.newBackgroundContext()
        let batch = try await makeBackfill().prepareBatch(in: background, before: nil, limit: 10)

        XCTAssertEqual(batch, Batch(lastMessageID: "001", stampedCount: 2, didDrain: true))
        XCTAssertTrue(stack.saveIfNeeded(context: background))
        let stored = try await storedVerdicts()
        let expected: [String: RichContentVerdict] = [
            "004": .notRich,
            "003": .rich,
            "002": .rich,
            "001": .notRich
        ]
        XCTAssertEqual(stored, expected)
    }

    // Revert-check: the descending `id` sort, the strict `id < %@` cursor predicate, and
    // `batch.lastMessageID = message.id` in `RichContentVerdictBackfill.prepareBatch`. An
    // ascending scan starts at "001"; `<=` re-examines "004" in the second batch, which then
    // ends at "003" having stamped one row.
    func testPrepareBatch_scansNewestFirst_andNextBatchContinuesBelowTheLowestExaminedID() async throws {
        // An own row above every received one: not examined, and it does not use up the limit.
        try row("006", fromMe: true)
        for number in 1...5 {
            try row(messageID(number))
        }
        try viewContext.save()
        let backfill = makeBackfill()
        let background = stack.newBackgroundContext()

        let first = try await backfill.prepareBatch(in: background, before: nil, limit: 2)
        XCTAssertEqual(first, Batch(lastMessageID: "004", stampedCount: 2, didDrain: false))
        XCTAssertTrue(stack.saveIfNeeded(context: background))
        let afterFirst = try await storedVerdicts()
        let expectedAfterFirst: [String: RichContentVerdict] = [
            "006": .unknown,
            "005": .notRich,
            "004": .notRich,
            "003": .unknown,
            "002": .unknown,
            "001": .unknown
        ]
        XCTAssertEqual(afterFirst, expectedAfterFirst)

        let second = try await backfill.prepareBatch(in: background, before: first.lastMessageID, limit: 2)
        XCTAssertEqual(second, Batch(lastMessageID: "002", stampedCount: 2, didDrain: false))
        XCTAssertTrue(stack.saveIfNeeded(context: background))

        // Fewer rows than the limit remain: this batch drains.
        let third = try await backfill.prepareBatch(in: background, before: second.lastMessageID, limit: 2)
        XCTAssertEqual(third, Batch(lastMessageID: "001", stampedCount: 1, didDrain: true))
    }

    // Revert-check: `didDrain: messages.count < limit` in
    // `RichContentVerdictBackfill.prepareBatch`. `<=` drains on a full batch, which would
    // latch the pass with rows below the cursor never examined whenever the store holds more.
    func testPrepareBatch_exactlyLimitRowsRemain_drainsOnlyOnTheFollowingEmptyBatch() async throws {
        try row("002")
        try row("001")
        try viewContext.save()
        let backfill = makeBackfill()
        let background = stack.newBackgroundContext()

        let full = try await backfill.prepareBatch(in: background, before: nil, limit: 2)
        XCTAssertEqual(full, Batch(lastMessageID: "001", stampedCount: 2, didDrain: false))
        XCTAssertTrue(stack.saveIfNeeded(context: background))

        // Nothing below the cursor: it stays where it was.
        let empty = try await backfill.prepareBatch(in: background, before: full.lastMessageID, limit: 2)
        XCTAssertEqual(empty, Batch(lastMessageID: "001", stampedCount: 0, didDrain: true))
    }

    // Revert-check: `Batch(lastMessageID: messageID, didDrain: messages.count < limit)` in
    // `RichContentVerdictBackfill.prepareBatch`, for a store with no received row at all.
    func testPrepareBatch_emptyStore_drainsImmediately() async throws {
        let batch = try await makeBackfill().prepareBatch(
            in: stack.newBackgroundContext(),
            before: nil,
            limit: 10
        )

        XCTAssertEqual(batch, Batch(lastMessageID: nil, stampedCount: 0, didDrain: true))
    }

    // Revert-check: the `captureAccountGeneration()` guard that throws
    // `BackfillError.htmlStorageClosed` in `RichContentVerdictBackfill.prepareBatch`. Without
    // the throw every read answers "absent", the batch returns with its cursor advanced past
    // rows it could not evaluate, and the caller persists that cursor.
    func testPrepareBatch_htmlStorageClosed_throwsAndStampsNothing() async throws {
        try row("001", html: richHTML)
        try viewContext.save()
        handler.closeAccountWork()

        let background = stack.newBackgroundContext()
        do {
            _ = try await makeBackfill().prepareBatch(in: background, before: nil, limit: 10)
            XCTFail("A closed HTML store cannot establish any row's verdict")
        } catch RichContentVerdictBackfill.BackfillError.htmlStorageClosed {
            // Expected: the caller must not advance its cursor.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let hasChanges = await background.perform { background.hasChanges }
        XCTAssertFalse(hasChanges)
        let stored = try await storedVerdicts()
        let expected: [String: RichContentVerdict] = ["001": .unknown]
        XCTAssertEqual(stored, expected)
    }

    // Revert-check: `ClassifierCandidate.undetermined` for a file that exists but does not
    // load, in `RichContentVerdictResolver.classifierCandidate` (falling through to the next
    // candidate stamps "002" not rich from its plain body), and `batch.lastMessageID =
    // message.id` sitting outside the stamped branch of
    // `RichContentVerdictBackfill.prepareBatch` (inside it, the first batch's cursor stops at
    // "003" and the unreadable row is fetched again by every later batch).
    func testPrepareBatch_unreadableHTMLFile_leavesRowUnknownAndAdvancesPastIt() async throws {
        try row("003", html: plainHTML)
        try row("002")
        // Invalid UTF-8, written straight to disk: `saveHTML` would cache the string, and a
        // cached string is never read back from the file.
        try Data([0xC3, 0x28, 0xFF, 0xFE]).write(to: directory.appendingPathComponent("002.html"))
        try row("001")
        try viewContext.save()
        XCTAssertTrue(handler.htmlFileExists(for: "002"), "Precondition: the file exists")
        XCTAssertNil(handler.loadHTML(for: "002"), "Precondition: and cannot be read")
        let backfill = makeBackfill()
        let background = stack.newBackgroundContext()

        let first = try await backfill.prepareBatch(in: background, before: nil, limit: 2)
        XCTAssertEqual(first, Batch(lastMessageID: "002", stampedCount: 1, didDrain: false))
        XCTAssertTrue(stack.saveIfNeeded(context: background))

        let second = try await backfill.prepareBatch(in: background, before: first.lastMessageID, limit: 2)
        XCTAssertEqual(second, Batch(lastMessageID: "001", stampedCount: 1, didDrain: true))
        XCTAssertTrue(stack.saveIfNeeded(context: background))

        let stored = try await storedVerdicts()
        let expected: [String: RichContentVerdict] = [
            "003": .notRich,
            "002": .unknown,
            "001": .notRich
        ]
        XCTAssertEqual(stored, expected)
    }

    // MARK: - ConversationLaunchRepairCoordinator.backfillRichContentVerdicts

    // Revert-check: the cursor and latch writes after a saved batch in
    // `ConversationLaunchRepairCoordinator.prepareAndSaveRichContentVerdictBatch` (a batch
    // that does not drain persists its cursor; the draining one sets the flag and clears the
    // cursor), and the `richContentVerdictBackfillMigrationKey` guard in
    // `backfillRichContentVerdicts` (without it the second call scans again and stamps the
    // late row).
    func testCoordinatorBackfill_stampsEveryReceivedRowThenLatchesAndClearsCursor_secondCallIsANoOp() async throws {
        // Two more received rows than one batch holds: the first batch fills and persists a
        // cursor, the second drains.
        let ownID = messageID(batchSize + 3)
        let richID = messageID(batchSize + 2)
        try row(ownID, html: richHTML, fromMe: true)
        try row(richID, html: richHTML)
        var expected: [String: RichContentVerdict] = [ownID: .unknown, richID: .rich]
        for number in 1...(batchSize + 1) {
            try row(messageID(number))
            expected[messageID(number)] = .notRich
        }
        try viewContext.save()

        let repair = makeCoordinator()
        repair.backfillRichContentVerdicts()
        await joinBackfill(repair)

        XCTAssertTrue(flags.bool(forKey: migrationKey))
        XCTAssertNil(flags.string(forKey: cursorKey))
        XCTAssertEqual(
            flags.stringWriteCount(forKey: cursorKey), 2,
            "One cursor write after the full batch, then the clear"
        )
        XCTAssertEqual(syncWaiter.waitForCurrentSyncToCompleteCalls, 2, "One sync wait per batch")
        let stored = try await storedVerdicts()
        XCTAssertEqual(stored, expected)

        // A row that turns up unstamped after the latch stays that way: the persister stamps
        // what it writes, and a bubble load re-stamps anything it finds unknown.
        let lateID = messageID(batchSize + 4)
        try row(lateID)
        try viewContext.save()
        expected[lateID] = .unknown

        repair.backfillRichContentVerdicts()
        await joinBackfill(repair)

        XCTAssertEqual(syncWaiter.waitForCurrentSyncToCompleteCalls, 2)
        let afterSecondCall = try await storedVerdicts()
        XCTAssertEqual(afterSecondCall, expected)
        withExtendedLifetime(repair) {}
    }

    // Deliberate, unlike `repairMissingConversationPreviews`, which stays armed on an empty
    // store: every row the current build ingests is stamped as it is written, so a fresh
    // install that latches here leaves nothing behind.
    // Revert-check: the `batch.didDrain` branch of
    // `ConversationLaunchRepairCoordinator.prepareAndSaveRichContentVerdictBatch`, which
    // latches without a store-has-rows gate.
    func testCoordinatorBackfill_emptyStore_latches() async {
        let repair = makeCoordinator()
        repair.backfillRichContentVerdicts()
        await joinBackfill(repair)

        XCTAssertTrue(flags.bool(forKey: migrationKey))
        XCTAssertNil(flags.string(forKey: cursorKey))
        withExtendedLifetime(repair) {}
    }

    // Revert-check: `ConversationLaunchRepairCoordinator.prepareAndSaveRichContentVerdictBatch`
    // running outside `conversationMutationSerializer.performCleanupSensitiveMutation`
    // (contrast `runChatPreviewPass`). Routed through the gate, the batch queues behind the
    // hold below and the pass cannot latch until it is released, so the bounded wait fails.
    func testCoordinatorBackfill_cleanupSensitiveGateHeld_stillCompletes() async throws {
        try row("001", html: richHTML)
        try viewContext.save()
        let serializer = ConversationRollupMutationSerializer()
        let holdStarted = VerdictBackfillGate()
        let releaseHold = VerdictBackfillGate()
        // Stands in for an optimistic send, or a maintenance pass, holding the gate.
        let hold = Task {
            await serializer.performCleanupSensitiveMutation {
                await holdStarted.open()
                await releaseHold.wait()
            }
        }
        await holdStarted.wait()

        let repair = makeCoordinator(serializer: serializer)
        repair.backfillRichContentVerdicts()
        // A bounded poll, not a join: a pass waiting on the gate would never finish while
        // the hold is open, and joining it would hang the run instead of failing the test.
        await waitUntil("the backfill latches while the cleanup-sensitive gate is held") {
            self.flags.bool(forKey: self.migrationKey)
        }
        let storedWhileHeld = try await storedVerdicts()

        await releaseHold.open()
        await hold.value
        await joinBackfill(repair)

        let expected: [String: RichContentVerdict] = ["001": .rich]
        XCTAssertEqual(storedWhileHeld, expected)
        withExtendedLifetime(repair) {}
    }

    // Revert-check: `RichContentVerdictBackfill` being its own type rather than a
    // `ChatPreviewRepair.Pass`: `prepareBatch` never reads `OutboundSendMutationRecord`.
    // Under the preview passes' deferral this row is skipped and the pass stays unlatched for
    // as long as the send is retained.
    func testCoordinatorBackfill_conversationWithPendingSend_isStampedAndPassLatches() async throws {
        let received = try row("001", html: richHTML)
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "pending-send"
        record.createdAt = Date()
        record.conversationId = received.conversation?.id
        XCTAssertNotNil(record.conversationId, "Precondition: the record names the row's conversation")
        try viewContext.save()

        let repair = makeCoordinator()
        repair.backfillRichContentVerdicts()
        await joinBackfill(repair)

        let stored = try await storedVerdicts()
        let expected: [String: RichContentVerdict] = ["001": .rich]
        XCTAssertEqual(stored, expected)
        XCTAssertTrue(flags.bool(forKey: migrationKey))
        withExtendedLifetime(repair) {}
    }

    // Revert-check: the `saveOffMainActor(context, using: storage.saveIfNeeded)` term of the
    // guard in `ConversationLaunchRepairCoordinator.prepareAndSaveRichContentVerdictBatch`.
    // With the save's result ignored the first batch persists its cursor, the loop goes on to
    // a second batch, and that one latches the flag over rows that were never stamped. The
    // second run on the same coordinator also needs the `defer` that clears
    // `isRichContentVerdictBackfillRunning`.
    func testCoordinatorBackfill_failedSave_doesNotAdvanceCursorOrLatch_andNextRunStamps() async throws {
        // More than one batch, so a cursor would be written if the failed batch counted.
        let count = batchSize + 2
        for number in 1...count {
            try row(messageID(number))
        }
        try viewContext.save()
        saveSeam.setFailsSaves(true)
        let repair = makeCoordinator()

        repair.backfillRichContentVerdicts()
        await joinBackfill(repair)

        XCTAssertEqual(saveSeam.attemptCount, 1, "The run stops at the first failed batch")
        XCTAssertFalse(flags.bool(forKey: migrationKey))
        XCTAssertEqual(flags.stringWriteCount(forKey: cursorKey), 0)
        let afterFailure = try await storedVerdicts()
        XCTAssertEqual(afterFailure.count, count)
        XCTAssertTrue(afterFailure.values.allSatisfy { $0 == .unknown })

        saveSeam.setFailsSaves(false)
        repair.backfillRichContentVerdicts()
        await joinBackfill(repair)

        XCTAssertTrue(flags.bool(forKey: migrationKey))
        XCTAssertNil(flags.string(forKey: cursorKey))
        let afterRetry = try await storedVerdicts()
        XCTAssertEqual(afterRetry.count, count)
        XCTAssertTrue(afterRetry.values.allSatisfy { $0 == .notRich })
        withExtendedLifetime(repair) {}
    }

    // Revert-check: the unconditional `await accountWorkCoordinator.endRun(lease)` in
    // `ConversationLaunchRepairCoordinator.runRichContentVerdictBackfill`. Released only for a
    // batch that saved, the lease of a failed batch stays held and every later sign-out parks
    // in `beginQuiescence()`.
    func testCoordinatorBackfill_failedBatch_releasesItsAccountWorkLease() async throws {
        try row("001")
        try viewContext.save()
        saveSeam.setFailsSaves(true)
        let repair = makeCoordinator()

        repair.backfillRichContentVerdicts()
        await joinBackfill(repair)
        XCTAssertEqual(saveSeam.attemptCount, 1, "Precondition: the batch reached its save under a lease")

        await completeAccountTransition()
        withExtendedLifetime(repair) {}
    }

    // Revert-check: the `catch` in
    // `ConversationLaunchRepairCoordinator.prepareAndSaveRichContentVerdictBatch` returning
    // nil for `RichContentVerdictBackfill.BackfillError.htmlStorageClosed`, and `prepareBatch`
    // throwing it. A batch that returned normally here would drain, latch the pass, and
    // strand the row unknown for good.
    func testCoordinatorBackfill_htmlStorageClosed_doesNotLatch_andStampsOnceReopened() async throws {
        try row("001", html: richHTML)
        try viewContext.save()
        handler.closeAccountWork()
        let repair = makeCoordinator()

        repair.backfillRichContentVerdicts()
        await joinBackfill(repair)

        XCTAssertFalse(flags.bool(forKey: migrationKey))
        XCTAssertEqual(flags.stringWriteCount(forKey: cursorKey), 0)
        XCTAssertEqual(saveSeam.attemptCount, 0, "A refused batch has nothing to save")

        try handler.reopenAccountWork()
        repair.backfillRichContentVerdicts()
        await joinBackfill(repair)

        XCTAssertTrue(flags.bool(forKey: migrationKey))
        let stored = try await storedVerdicts()
        let expected: [String: RichContentVerdict] = ["001": .rich]
        XCTAssertEqual(stored, expected)
        withExtendedLifetime(repair) {}
    }

    // Revert-check: the account work request made once per run in
    // `ConversationLaunchRepairCoordinator.backfillRichContentVerdicts` and checked by
    // `acquireAccountWorkLease(kind:for:)` before every batch. A request re-made after the
    // sync wait is granted a lease in the next account, so the old run stamps that account's
    // rows from the old cursor and latches. The transition completing at all also needs
    // `endRun(lease)` after the first batch: quiescence drains leases.
    func testCoordinatorBackfill_accountTransitionBetweenBatches_stopsWithoutLatchingAndHoldsNoLease() async throws {
        let count = batchSize + 2
        for number in 1...count {
            try row(messageID(number))
        }
        try viewContext.save()
        // The first batch's sync wait passes; the second parks, with the first batch saved.
        let gate = VerdictBackfillGate(freePasses: 1)
        syncWaiter.onWaitForCurrentSyncToComplete = { await gate.wait() }
        let repair = makeCoordinator()
        repair.backfillRichContentVerdicts()
        await waitUntil("the second batch waits for sync") {
            self.syncWaiter.waitForCurrentSyncToCompleteCalls == 2
        }

        let transitioned = await completeAccountTransition()
        await gate.open()
        // A transition that never finished has already failed the test, and it leaves the
        // coordinator quiescing, so nothing below could say anything about the run.
        guard transitioned else { return }
        // Join the original worker before checking isolation, so the retry below cannot
        // hide an unsafe write or a latch.
        await joinBackfill(repair)

        // The first batch examined the newest `batchSize` rows; the two oldest are below it.
        let firstBatchCursor = messageID(count - batchSize + 1)
        var expected: [String: RichContentVerdict] = [:]
        for number in 1...count {
            let wasExamined = number > count - batchSize
            let verdict: RichContentVerdict = wasExamined ? .notRich : .unknown
            expected[messageID(number)] = verdict
        }
        XCTAssertFalse(flags.bool(forKey: migrationKey))
        XCTAssertEqual(flags.string(forKey: cursorKey), firstBatchCursor)
        XCTAssertEqual(saveSeam.attemptCount, 1, "Only the batch before the transition may save")
        let afterTransition = try await storedVerdicts()
        XCTAssertEqual(afterTransition, expected)

        // The next run makes its own request and resumes below the cursor.
        syncWaiter.onWaitForCurrentSyncToComplete = nil
        repair.backfillRichContentVerdicts()
        await joinBackfill(repair)

        XCTAssertTrue(flags.bool(forKey: migrationKey))
        XCTAssertNil(flags.string(forKey: cursorKey))
        let afterResume = try await storedVerdicts()
        XCTAssertEqual(afterResume.count, count)
        XCTAssertTrue(afterResume.values.allSatisfy { $0 == .notRich })
        withExtendedLifetime(repair) {}
    }

    // Revert-check: `context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy` in
    // `ConversationLaunchRepairCoordinator.prepareAndSaveRichContentVerdictBatch`. The
    // fixture's contexts come with object-trump, as `CoreDataStack`'s do, and under it the
    // batch's older "not rich" overwrites the verdict the other writer just committed.
    // HONEST SCOPE: the competing write is injected at the save seam, the one point between
    // a batch's fetch and its save this suite can reach deterministically. A writer landing
    // while `prepareBatch` is still classifying is the same conflict to Core Data (a row
    // snapshot older than the store's) but is not interleaved here.
    func testCoordinatorBackfill_verdictCommittedByAnotherWriterBeforeTheBatchSaves_survives() async throws {
        try row("002", html: plainHTML)
        try row("001", html: plainHTML)
        try viewContext.save()
        // Stands in for sync or the refresher: by the time the seam runs, the batch has
        // fetched "001" unknown and classified it as text.
        saveSeam.stampBeforeNextSave(messageID: "001", verdict: .rich)
        let repair = makeCoordinator()

        repair.backfillRichContentVerdicts()
        await joinBackfill(repair)

        XCTAssertEqual(saveSeam.competingStampCount, 1, "Precondition: the competing write committed")
        let stored = try await storedVerdicts()
        // "002" proves the same save carried the batch's own stamps.
        let expected: [String: RichContentVerdict] = ["002": .notRich, "001": .rich]
        XCTAssertEqual(stored, expected)
        XCTAssertTrue(flags.bool(forKey: migrationKey))
        withExtendedLifetime(repair) {}
    }

    // Revert-check: `saveOffMainActor` in `ConversationLaunchRepairCoordinator`. Calling
    // `storage.saveIfNeeded(context)` directly, as the preview passes do, runs this pass's
    // save (one per batch, mailbox-wide) on the main thread.
    func testCoordinatorBackfill_savesOffTheMainThread() async throws {
        try row("001")
        try viewContext.save()
        let repair = makeCoordinator()

        repair.backfillRichContentVerdicts()
        await joinBackfill(repair)

        XCTAssertEqual(saveSeam.attemptCount, 1)
        XCTAssertEqual(saveSeam.mainThreadAttemptCount, 0)
        withExtendedLifetime(repair) {}
    }

    // Revert-check: `var cursor = storage.migrationFlags.string(forKey:
    // Self.richContentVerdictBackfillCursorKey)` in
    // `ConversationLaunchRepairCoordinator.runRichContentVerdictBackfill`. Starting from nil
    // rescans the mailbox from the top and stamps "004" and "003".
    func testCoordinatorBackfill_inheritedCursor_scansOnlyBelowItAndStillLatches() async throws {
        for number in 1...4 {
            try row(messageID(number))
        }
        try viewContext.save()
        flags.setString("003", forKey: cursorKey)
        let repair = makeCoordinator()

        repair.backfillRichContentVerdicts()
        await joinBackfill(repair)

        let stored = try await storedVerdicts()
        // The cursor is the lowest ID already examined, so "003" itself is not scanned again.
        let expected: [String: RichContentVerdict] = [
            "004": .unknown,
            "003": .unknown,
            "002": .notRich,
            "001": .notRich
        ]
        XCTAssertEqual(stored, expected)
        XCTAssertTrue(flags.bool(forKey: migrationKey))
        XCTAssertNil(flags.string(forKey: cursorKey))
        withExtendedLifetime(repair) {}
    }

    // Revert-check: the `defer` clearing `isRichContentVerdictBackfillRunning` in
    // `ConversationLaunchRepairCoordinator.backfillRichContentVerdicts`. Without it the
    // cancelled run leaves the guard set and no repeat call ever starts a second run.
    // HONEST SCOPE: "a cancelled run stamps nothing" is held by more than one guard (the
    // `Task.isCancelled` check after the sync wait, and the one that opens
    // `prepareAndSaveRichContentVerdictBatch`), so removing either alone does not fail this.
    func testCancel_whileWaitingForSync_stampsNothingAndLeavesBackfillRerunnable() async throws {
        try row("001", html: richHTML)
        try viewContext.save()
        let firstRunGate = VerdictBackfillGate()
        syncWaiter.onWaitForCurrentSyncToComplete = { await firstRunGate.wait() }
        let repair = makeCoordinator()
        repair.backfillRichContentVerdicts()
        await waitUntil("the first run waits for sync") {
            self.syncWaiter.waitForCurrentSyncToCompleteCalls == 1
        }

        repair.cancel()
        // The rerun parks on a gate of its own, so what the cancelled run left behind can
        // be read before the rerun stamps anything.
        let rerunGate = VerdictBackfillGate()
        syncWaiter.onWaitForCurrentSyncToComplete = { await rerunGate.wait() }
        await firstRunGate.open()
        // A repeat call starts a run only once the cancelled one has exited and cleared the
        // running guard, and that run's sync wait is the second one.
        await waitUntil("a rerun starts once the cancelled run has exited") {
            repair.backfillRichContentVerdicts()
            return self.syncWaiter.waitForCurrentSyncToCompleteCalls >= 2
        }

        XCTAssertFalse(flags.bool(forKey: migrationKey))
        XCTAssertEqual(flags.stringWriteCount(forKey: cursorKey), 0)
        XCTAssertEqual(saveSeam.attemptCount, 0)
        let afterCancel = try await storedVerdicts()
        let expectedAfterCancel: [String: RichContentVerdict] = ["001": .unknown]
        XCTAssertEqual(afterCancel, expectedAfterCancel)

        await rerunGate.open()
        await joinBackfill(repair)

        XCTAssertTrue(flags.bool(forKey: migrationKey))
        let afterRerun = try await storedVerdicts()
        let expectedAfterRerun: [String: RichContentVerdict] = ["001": .rich]
        XCTAssertEqual(afterRerun, expectedAfterRerun)
        withExtendedLifetime(repair) {}
    }

    // Revert-check: `richContentVerdictBackfillCursorKey` staying out of
    // `ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKeys`. Conversation
    // maintenance decodes every key in that list as a `ChatPreviewRepair.Checkpoint` to find
    // deferred conversations; this cursor is a bare message ID and the pass defers none.
    func testCursorKey_isNotAChatPreviewCheckpointKey() {
        XCTAssertFalse(
            ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKeys.contains(cursorKey)
        )
    }

    // MARK: - Triggers

    // Revert-check: `backfillRichContentVerdicts()` in
    // `ConversationLaunchRepairCoordinator.runLaunchRepairsIfNeeded`, as a task of its own.
    // Run as a third pass inside `repairPersistedChatPreviews` it never starts here: that
    // function returns early once both preview flags are latched, which they are on every
    // device that upgrades to this build.
    func testRunLaunchRepairsIfNeeded_previewPassesAlreadyLatched_stillRunsBackfill() async throws {
        try row("001", html: richHTML)
        try viewContext.save()
        latchEarlierLaunchPasses()
        let repair = makeCoordinator()

        repair.runLaunchRepairsIfNeeded()
        await joinBackfill(repair)

        XCTAssertTrue(flags.bool(forKey: migrationKey))
        let stored = try await storedVerdicts()
        let expected: [String: RichContentVerdict] = ["001": .rich]
        XCTAssertEqual(stored, expected)
        withExtendedLifetime(repair) {}
    }

    // Revert-check: `self.backfillRichContentVerdicts()` in the `.syncCompleted` sink of
    // `ConversationLaunchRepairCoordinator.bindSyncCompletionRepairRearm`. A run that a
    // failed save or an account transition stopped has no other retry before the next launch.
    func testSyncCompleted_onInjectedCenter_runsBackfill() async throws {
        try row("001", html: richHTML)
        try viewContext.save()
        latchEarlierLaunchPasses()
        // Constructed only, never poked: the posted notification is the sole trigger.
        let repair = makeCoordinator()

        notificationCenter.post(name: .syncCompleted, object: nil)

        await waitUntil("the sync-completion re-arm runs the backfill to its latch") {
            self.flags.bool(forKey: self.migrationKey)
        }
        await joinBackfill(repair)
        let stored = try await storedVerdicts()
        let expected: [String: RichContentVerdict] = ["001": .rich]
        XCTAssertEqual(stored, expected)
        withExtendedLifetime(repair) {}
    }

    // MARK: - Helpers

    private func makeBackfill() -> RichContentVerdictBackfill {
        RichContentVerdictBackfill(htmlContentHandler: handler)
    }

    private func messageID(_ number: Int) -> String {
        String(format: "%03d", number)
    }

    /// A received row (unless `fromMe`) in a conversation of its own, with `html` stored
    /// under its message ID and named by `bodyStorageURI`. Its default body and snippet are
    /// plain prose, so a row without HTML resolves to not rich.
    @discardableResult
    private func row(_ id: String, html: String? = nil, fromMe: Bool = false) throws -> Message {
        let conversation = ConversationBuilder().build(in: viewContext)
        let builder = MessageBuilder().withId(id).inConversation(conversation)
        let message = (fromMe ? builder.fromMe() : builder).build(in: viewContext)
        if let html {
            message.bodyStorageURI = try XCTUnwrap(handler.saveHTML(html, for: id)).absoluteString
        }
        return message
    }

    /// The persisted verdict of every message, keyed by ID, read through a fresh context.
    private func storedVerdicts() async throws -> [String: RichContentVerdict] {
        let context = stack.newBackgroundContext()
        let verdicts: [String: RichContentVerdict] = try await context.perform {
            let request = Message.fetchRequest()
            var result: [String: RichContentVerdict] = [:]
            for message in try context.fetch(request) {
                result[message.id] = message.storedRichContentVerdict
            }
            return result
        }
        return verdicts
    }

    /// An already-upgraded device: the name refresh and both persisted-preview passes
    /// latched long ago, so of the flag-gated passes only the backfill has work.
    private func latchEarlierLaunchPasses() {
        flags.set(true, forKey: ConversationLaunchRepairCoordinator.conversationNameRefreshMigrationKey)
        flags.set(true, forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey)
        flags.set(true, forKey: ConversationLaunchRepairCoordinator.blankChatPreviewBackfillMigrationKey)
    }

    /// Every save goes through `saveSeam`, and every collaborator is the suite's own, so no
    /// run takes a lease on `SyncRunCoordinator.shared` or reads the real Messages directory.
    private func makeCoordinator(
        serializer: ConversationRollupMutationSerializer? = nil
    ) -> ConversationLaunchRepairCoordinator {
        let stack: TestCoreDataStack = self.stack
        return ConversationLaunchRepairCoordinator(
            storage: StorageDependencies(
                viewContext: viewContext,
                makeBackgroundContext: { stack.newBackgroundContext() },
                saveIfNeeded: saveSeam.makeSave(),
                migrationFlags: flags,
                personCache: Dependencies.shared.personCache,
                profilePhotoResolver: Dependencies.shared.profilePhotoResolver
            ),
            conversationManager: ConversationManager(currentUserEmail: { "me@example.com" }),
            syncWaiter: syncWaiter,
            notificationCenter: notificationCenter,
            conversationMutationSerializer: serializer ?? ConversationRollupMutationSerializer(),
            accountWorkCoordinator: accountWork,
            htmlContentHandler: handler,
            // Inherit the test's priority: see repairTaskPriority's doc.
            repairTaskPriority: nil
        )
    }

    /// Runs an account transition (quiesce, then reopen) on the suite's coordinator and
    /// reports whether it finished. Quiescence drains every account work lease, so a leaked
    /// one parks `beginQuiescence()` for good; the bounded poll turns that into a failed
    /// test rather than a hung run.
    @discardableResult
    private func completeAccountTransition(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        let accountWork: SyncRunCoordinator = self.accountWork
        let finished = VerdictBackfillLatch()
        Task {
            await accountWork.beginQuiescence()
            await accountWork.endQuiescence()
            finished.set()
        }
        return await waitUntil("account teardown drains every account work lease", file: file, line: line) {
            finished.isSet
        }
    }

    // Joins the backfill worker, bounded. The worker's loop exits only on drain, a refused
    // batch or cancellation, so a cursor that stopped advancing would spin forever and a
    // bare join would hang the whole run instead of failing a test by name. The join is
    // started before any cancel: `cancel()` drops the task key, and a join issued after it
    // would return at once without waiting for the worker.
    private func joinBackfill(
        _ repair: ConversationLaunchRepairCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let finished = VerdictBackfillLatch()
        let join = Task { @MainActor in
            await repair.waitForRichContentVerdictBackfillCompletion()
            finished.set()
        }
        let exited = await waitUntil("the backfill run exits", file: file, line: line) { finished.isSet }
        if !exited {
            repair.cancel()
        }
        await join.value
    }

    // Bounded by a wall-clock deadline with a poll interval, the shape
    // ConversationLaunchRepairCoordinatorTests uses. Coordinators here pass
    // `repairTaskPriority: nil`, so the worker inherits the test's priority and a green run
    // returns at the first successful poll; the deadline is only a liveness bound.
    @discardableResult
    private func waitUntil(
        _ expectation: String,
        timeout: TimeInterval = 30,
        pollIntervalNanoseconds: UInt64 = 50_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        XCTFail("Timed out waiting until \(expectation)", file: file, line: line)
        return false
    }
}

/// Parks waiters until `open()`, and remembers being opened so a waiter arriving later
/// passes straight through. The first `freePasses` waiters are let through unparked, which
/// lets a test stop a run at its second sync wait rather than its first.
private actor VerdictBackfillGate {
    private var isOpen = false
    private var freePasses: Int
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(freePasses: Int = 0) {
        self.freePasses = freePasses
    }

    func wait() async {
        guard !isOpen else { return }
        if freePasses > 0 {
            freePasses -= 1
            return
        }
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

/// A flag a task sets and the test polls.
///
/// `@unchecked Sendable`: every access to `value` takes `lock`.
private final class VerdictBackfillLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// The suite's `storage.saveIfNeeded`: counts saves, can fail them, and can commit a
/// competing verdict from another context just before the next save.
///
/// The coordinator calls this seam off the main actor for the backfill (`saveOffMainActor`),
/// so the closure is formed here, in a type with no actor isolation, rather than in the
/// `@MainActor` suite.
///
/// `@unchecked Sendable`: every access to the mutable state takes `lock`; `stack` is
/// immutable and performs its own work on the context's queue.
private final class VerdictBackfillSaveSeam: @unchecked Sendable {
    private struct CompetingStamp {
        let messageID: String
        let verdict: RichContentVerdict
    }

    private let stack: TestCoreDataStack
    private let lock = NSLock()
    private var failsSaves = false
    private var attempts = 0
    private var mainThreadAttempts = 0
    private var pendingStamp: CompetingStamp?
    private var committedStamps = 0

    init(stack: TestCoreDataStack) {
        self.stack = stack
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    var mainThreadAttemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mainThreadAttempts
    }

    var competingStampCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return committedStamps
    }

    func setFailsSaves(_ fails: Bool) {
        lock.lock()
        failsSaves = fails
        lock.unlock()
    }

    /// Before the next save, another context stamps `verdict` on the message and commits.
    func stampBeforeNextSave(messageID: String, verdict: RichContentVerdict) {
        lock.lock()
        pendingStamp = CompetingStamp(messageID: messageID, verdict: verdict)
        lock.unlock()
    }

    func makeSave() -> (NSManagedObjectContext) -> Bool {
        return { [self] context in
            let isMainThread = Thread.isMainThread
            lock.lock()
            attempts += 1
            if isMainThread {
                mainThreadAttempts += 1
            }
            let fails = failsSaves
            let stamp = pendingStamp
            pendingStamp = nil
            lock.unlock()

            if let stamp, VerdictBackfillSaveSeam.commit(stamp, in: stack) {
                lock.lock()
                committedStamps += 1
                lock.unlock()
            }
            return fails ? false : stack.saveIfNeeded(context: context)
        }
    }

    private static func commit(_ stamp: CompetingStamp, in stack: TestCoreDataStack) -> Bool {
        let context = stack.newBackgroundContext()
        var committed = false
        context.performAndWait {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", stamp.messageID)
            do {
                guard let message = try context.fetch(request).first else { return }
                message.storedRichContentVerdict = stamp.verdict
                try context.save()
                committed = true
            } catch {
                committed = false
            }
        }
        return committed
    }
}
