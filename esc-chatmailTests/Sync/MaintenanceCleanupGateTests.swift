import XCTest
import CoreData
@testable import esc_chatmail

/// Pins how the 6-hour store maintenance shares the cleanup-sensitive gate
/// with optimistic-send creation: each pass takes the gate on its own, a
/// mutation queued mid-run lands between two passes, later passes honor what
/// it committed, and the cadence is marked only once the last pass ran.
///
/// The queued mutation is injected from `identityAliasProvider`, which only
/// `fixAndMergeIncorrectParticipantHashes` (pass 3) calls here — the two
/// flag-gated migrations that also call it are latched off — so it runs
/// while pass 3 holds the gate and before `removeEmptyConversations`
/// (pass 4) starts.
///
/// The passes are a run of their own, `runStoreMaintenanceIfDue`, started
/// after the sync that found them due has ended its run. They were the tail
/// of `runIncrementalCleanup`, inside the sync's run.
///
/// Every fixture access goes through `performAndWait` on the private-queue
/// `stack.viewContext`, and the tests keep only `UUID`s across awaits; see
/// `DuplicateLabelMergeTests` for the off-queue crash that shape avoids.
final class MaintenanceCleanupGateTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var scheduleDefaults: UserDefaults!
    private var scheduleSuiteName: String!

    private static let me = "me@example.com"

    override func setUp() {
        super.setUp()
        // SQLite: the empty-conversation and duplicate passes use
        // NSBatchDeleteRequest, which an in-memory store rejects.
        stack = TestCoreDataStack(storeKind: .sqlite)
        coreDataStack = CoreDataStack(persistentContainerForTesting: stack.persistentContainer)
        scheduleSuiteName = "MaintenanceCleanupGateTests.\(UUID().uuidString)"
        scheduleDefaults = UserDefaults(suiteName: scheduleSuiteName)
    }

    override func tearDown() {
        scheduleDefaults.removePersistentDomain(forName: scheduleSuiteName)
        scheduleDefaults = nil
        scheduleSuiteName = nil
        coreDataStack = nil
        stack = nil
        super.tearDown()
    }

    // Revert-check: `DataCleanupService.runMaintenancePassesCooperatively`.
    // Wrapping all eight passes back in one `performCleanupSensitiveMutation`
    // makes the queued mutation run after `removeEmptyConversations`, so it
    // no longer sees the empty shell and both assertions fail.
    func testRunStoreMaintenanceIfDue_mutationQueuedDuringMaintenance_runsBeforeNextPassAndIsHonored() async throws {
        let shellID = try seedEmptyConversationShell()
        let serializer = ConversationRollupMutationSerializer()
        let probe = QueuedMutationProbe()
        let stack = self.stack!
        let service = makeService(serializer: serializer) { _ in
            await probe.enqueueOnce {
                await serializer.performCleanupSensitiveMutation(onEnqueued: {
                    await probe.markEnqueued()
                }, operation: {
                    // Stands in for an optimistic reply anchoring to the
                    // shell: commit its mutation record, as
                    // `createOptimisticMessage` does under this same gate.
                    let context = stack.newBackgroundContext()
                    return await context.perform {
                        let shellExisted = Self.conversationExists(shellID, in: context)
                        let record = context.insertTestObject(OutboundSendMutationRecord.self)
                        record.id = "queued-optimistic-send"
                        record.createdAt = Date()
                        record.conversationId = shellID
                        try? context.save()
                        return shellExisted
                    }
                })
            }
            return [Self.me]
        }

        let outcome = await service.runStoreMaintenanceIfDue(in: stack.newBackgroundContext())

        XCTAssertEqual(outcome, .finished(.completed))
        let shellExistedWhenMutationRan = await probe.result()
        XCTAssertEqual(
            shellExistedWhenMutationRan, true,
            "A send queued during maintenance must run after the current pass, not after every pass"
        )
        XCTAssertTrue(
            conversationExistsInStore(shellID),
            "Later passes must re-read pending sends committed between passes and keep their anchor"
        )
        XCTAssertFalse(
            DataCleanupService.IncrementalCleanupSchedule.isDue(defaults: scheduleDefaults),
            "A completed maintenance run marks the cadence"
        )
    }

    // Revert-check: the `Task.isCancelled` guard in
    // `runMaintenancePassesCooperatively` and `markRun` sitting after it in
    // `runStoreMaintenanceIfDue(in:)`. Without the guard the remaining passes run and
    // the cadence is marked, so the empty shell is deleted and `isDue` is false.
    func testRunStoreMaintenanceIfDue_cancelledBetweenPasses_stopsAndLeavesCadenceDue() async throws {
        let shellID = try seedEmptyConversationShell()
        let relay = CancellationRelay()
        let service = makeService(serializer: ConversationRollupMutationSerializer()) { _ in
            await relay.cancelOnce()
            return [Self.me]
        }
        let context = stack.newBackgroundContext()
        let run = Task { _ = await service.runStoreMaintenanceIfDue(in: context) }
        await relay.register(run)
        await run.value

        XCTAssertTrue(
            conversationExistsInStore(shellID),
            "Passes after the cancellation point must not run"
        )
        XCTAssertTrue(
            DataCleanupService.IncrementalCleanupSchedule.isDue(defaults: scheduleDefaults),
            "An interrupted maintenance run must retry at the next sync"
        )
    }

    // Revert-check: the `if !saved { context.rollback() }` line in
    // `DataCleanupService.settleCleanupSensitiveHold`, and the `.saveFailed`
    // outcome (`didFailSave` in `runMaintenancePassesCooperatively`) that
    // keeps `runStoreMaintenanceIfDue(in:)` from marking the cadence. Pass 3
    // stages a deletion and its hold's save fails. Without the rollback the
    // staged deletion survives into the next pass, whose save commits it (by
    // then a reply could have anchored to that conversation); without the
    // outcome check the run marks the cadence although pass 3's work was lost.
    func testRunStoreMaintenanceIfDue_passSaveFails_rollsBackStagedDeletionAndLeavesCadenceDue() async throws {
        let victimID = try seedConversationWithMessage()
        let service = makeServiceFailingPassThreeSave(stagingDeletionOf: victimID)

        let outcome = await service.runStoreMaintenanceIfDue(in: stack.newBackgroundContext())

        XCTAssertEqual(outcome, .finished(.saveFailed))

        XCTAssertTrue(
            conversationExistsInStore(victimID),
            "A failed pass's staged deletion must not be committed by a later pass"
        )
        XCTAssertTrue(
            DataCleanupService.IncrementalCleanupSchedule.isDue(defaults: scheduleDefaults),
            "A run with a failed pass save must retry at the next sync"
        )
    }

    // Revert-check: `didFailSave` in `runMaintenancePassesCooperatively`.
    // The rollback leaves the context clean, so `DatabaseMaintenanceService`'s
    // own save afterwards succeeds; reporting `.completed` here would let
    // database cleanup report success for a run whose pass never committed.
    func testRunMaintenanceCleanup_passSaveFails_reportsSaveFailedWithCleanContext() async throws {
        let victimID = try seedConversationWithMessage()
        let service = makeServiceFailingPassThreeSave(stagingDeletionOf: victimID)
        let context = stack.newBackgroundContext()

        let outcome = await service.runMaintenanceCleanup(in: context)

        XCTAssertEqual(outcome, .saveFailed)
        let hasChanges = await context.perform { context.hasChanges }
        XCTAssertFalse(hasChanges, "The failed pass is rolled back, not left staged")
        XCTAssertTrue(conversationExistsInStore(victimID))
    }

    // HONEST SCOPE: pins pre-existing cadence gating, now read from the
    // injected defaults; it guards no new fix and has no revert target.
    func testRunStoreMaintenanceIfDue_cadenceNotDue_skipsMaintenancePasses() async throws {
        let shellID = try seedEmptyConversationShell()
        DataCleanupService.IncrementalCleanupSchedule.markRun(defaults: scheduleDefaults)
        let service = makeService(serializer: ConversationRollupMutationSerializer()) { _ in [Self.me] }

        let outcome = await service.runStoreMaintenanceIfDue(in: stack.newBackgroundContext())

        XCTAssertEqual(outcome, .notDue)
        XCTAssertTrue(conversationExistsInStore(shellID), "Maintenance must not run before its cadence is due")
    }

    // MARK: - Announcing a finished run

    // Revert-check: the `defer { announceCleanupFinished() }` in
    // `DataCleanupService.runMaintenanceCleanup`. The daily database cleanup
    // runs these passes outside any sync, so nothing else says that they
    // rewrote participant rows or merged conversations, and a chat left open
    // went on naming a reply's recipients from what it read before. The
    // announcement comes after the passes' own saves: a listener that reads
    // on hearing it must find what they wrote.
    func testRunMaintenanceCleanup_announcesOnceAfterItsSaves() async throws {
        let shellID = try seedEmptyConversationShell()
        let stack = self.stack!
        let announcements = AnnouncementLog()
        let service = makeService(announceCleanupFinished: {
            let context = stack.newBackgroundContext()
            announcements.record(
                shellExisted: context.performAndWait { Self.conversationExists(shellID, in: context) }
            )
        })

        let outcome = await service.runMaintenanceCleanup(in: stack.newBackgroundContext())

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(
            announcements.shellExistedAtEach, [false],
            "One announcement, made once the pass that removes the empty shell had saved"
        )
    }

    // Revert-check: the `defer { announceCleanupFinished() }` in
    // `DataCleanupService.runIncrementalCleanup`. Its hold is where contact
    // links are adopted, so every run has to say it ended.
    func testRunIncrementalCleanup_announcesOnce() async {
        let announcements = AnnouncementLog()
        let service = makeService(announceCleanupFinished: { announcements.record(shellExisted: false) })

        await service.runIncrementalCleanup(in: stack.newBackgroundContext())

        XCTAssertEqual(announcements.count, 1)
    }

    // HONEST SCOPE: the announcement of a run that ran is
    // `runMaintenanceCleanup`'s, pinned above; this pins that the cadence
    // check in front of it announces nothing for a run that did not happen.
    func testRunStoreMaintenanceIfDue_announcesOnlyForARunThatRan() async {
        let announcements = AnnouncementLog()
        let service = makeService(announceCleanupFinished: { announcements.record(shellExisted: false) })

        let first = await service.runStoreMaintenanceIfDue(in: stack.newBackgroundContext())
        XCTAssertEqual(first, .finished(.completed))
        XCTAssertEqual(announcements.count, 1, "A run whose passes were due")

        let second = await service.runStoreMaintenanceIfDue(in: stack.newBackgroundContext())
        XCTAssertEqual(second, .notDue)
        XCTAssertEqual(announcements.count, 1, "Nothing ran, so nothing ended")
    }

    // MARK: - A run of its own, after the sync

    // Revert-check: put the cadence check and `runMaintenancePassesCooperatively`
    // back at the end of `DataCleanupService.runIncrementalCleanup(in:)`. That
    // function runs inside the sync's run, ahead of `.syncCompleted`, and the
    // sync that met the 6-hour cadence then held its run for every store-wide
    // pass: the shell is deleted here and the cadence is marked.
    func testRunIncrementalCleanup_cadenceDue_leavesTheStoreWidePassesToTheirOwnRun() async throws {
        let shellID = try seedEmptyConversationShell()
        let service = makeService(serializer: ConversationRollupMutationSerializer()) { _ in [Self.me] }
        XCTAssertTrue(DataCleanupService.IncrementalCleanupSchedule.isDue(defaults: scheduleDefaults))

        await service.runIncrementalCleanup(in: stack.newBackgroundContext())

        XCTAssertTrue(
            conversationExistsInStore(shellID),
            "The per-sync cleanup must not run the store-wide passes"
        )
        XCTAssertTrue(
            DataCleanupService.IncrementalCleanupSchedule.isDue(defaults: scheduleDefaults),
            "The cadence stays due for the maintenance run that follows the sync"
        )
    }

    // Revert-check: `runExclusivelyWhenStoreIsIdle` in
    // `DataCleanupService.runStoreMaintenanceIfDue(exclusiveRunner:)`. Run
    // without it, the passes start while the sync's run is still active (the
    // shell is gone before the run ends) and hold no run of their own (the
    // kind read from inside a pass is the sync's, then nil).
    func testRunStoreMaintenanceIfDue_whileASyncRunIsActive_waitsThenHoldsTheMaintenanceRun() async throws {
        let shellID = try seedEmptyConversationShell()
        let syncRunCoordinator = SyncRunCoordinator()
        let exclusiveRunner = StoreMaintenanceCoordinator(syncRunCoordinator: syncRunCoordinator)
        let runKinds = RunKindLog()
        let service = makeService(serializer: ConversationRollupMutationSerializer()) { _ in
            await runKinds.record(await syncRunCoordinator.activeRunKind())
            return [Self.me]
        }
        let beganSync = await syncRunCoordinator.beginRun(kind: .foregroundIncremental)
        let syncRun = try XCTUnwrap(beganSync)

        let maintenance = Task { await service.runStoreMaintenanceIfDue(exclusiveRunner: exclusiveRunner) }
        let waited = await workIsWaiting(on: syncRunCoordinator)
        XCTAssertTrue(waited, "The maintenance waits for the sync's run to end")
        XCTAssertTrue(conversationExistsInStore(shellID), "No pass may run while the sync holds its run")

        await syncRunCoordinator.endRun(syncRun)
        let outcome = await maintenance.value

        XCTAssertEqual(outcome, .finished(.completed))
        XCTAssertFalse(conversationExistsInStore(shellID))
        let kinds = await runKinds.kinds
        XCTAssertFalse(kinds.isEmpty, "The hash-repair pass asks for the aliases")
        XCTAssertTrue(
            kinds.allSatisfy { $0 == .maintenance },
            "The passes run inside the exclusive maintenance run, got \(kinds)"
        )
        let stillRunning = await syncRunCoordinator.isRunning()
        XCTAssertFalse(stillRunning, "The maintenance run is ended")
        XCTAssertFalse(DataCleanupService.IncrementalCleanupSchedule.isDue(defaults: scheduleDefaults))
    }

    // Revert-check: the `isDue` guard ahead of the exclusive run in
    // `DataCleanupService.runStoreMaintenanceIfDue(exclusiveRunner:)`.
    // Without it every sync's follow-up waits for the boundary to learn that
    // nothing is due; here that wait never ends, and the deadline fails the
    // test.
    func testRunStoreMaintenanceIfDue_cadenceNotDue_answersWithoutWaitingForTheBoundary() async throws {
        DataCleanupService.IncrementalCleanupSchedule.markRun(defaults: scheduleDefaults)
        let syncRunCoordinator = SyncRunCoordinator()
        let exclusiveRunner = StoreMaintenanceCoordinator(syncRunCoordinator: syncRunCoordinator)
        let service = makeService(serializer: ConversationRollupMutationSerializer()) { _ in [Self.me] }
        let beganSync = await syncRunCoordinator.beginRun(kind: .foregroundIncremental)
        let syncRun = try XCTUnwrap(beganSync)
        let answer = OutcomeBox()

        let maintenance = Task {
            answer.set(await service.runStoreMaintenanceIfDue(exclusiveRunner: exclusiveRunner))
        }
        let answered = await waitUntil(timeout: 5) { answer.value != nil }
        await syncRunCoordinator.endRun(syncRun)
        await maintenance.value

        XCTAssertTrue(answered, "A cadence that is not due must not wait for the run to end")
        XCTAssertEqual(answer.value, .notDue)
    }

    // Revert-check: the account-work request in
    // `StoreMaintenanceCoordinator.runExclusivelyWhenStoreIsIdle`, which
    // `runStoreMaintenanceIfDue(exclusiveRunner:)` goes through. A sign-out
    // that starts while the maintenance waits behind the sync must find it
    // gone, not let it run its merges on the next account's store.
    func testRunStoreMaintenanceIfDue_accountTransitionWhileWaiting_runsNothingAndStaysDue() async throws {
        let shellID = try seedEmptyConversationShell()
        let syncRunCoordinator = SyncRunCoordinator()
        let exclusiveRunner = StoreMaintenanceCoordinator(syncRunCoordinator: syncRunCoordinator)
        let service = makeService(serializer: ConversationRollupMutationSerializer()) { _ in [Self.me] }
        let beganSync = await syncRunCoordinator.beginRun(kind: .foregroundIncremental)
        let syncRun = try XCTUnwrap(beganSync)

        let maintenance = Task { await service.runStoreMaintenanceIfDue(exclusiveRunner: exclusiveRunner) }
        let waited = await workIsWaiting(on: syncRunCoordinator)
        XCTAssertTrue(waited, "The maintenance waits for the sync's run to end")
        let transition = Task { await syncRunCoordinator.beginQuiescence() }
        let quiescing = await waitUntil(timeout: 5) {
            await syncRunCoordinator.makeAccountWorkRequest() == nil
        }
        XCTAssertTrue(quiescing)
        await syncRunCoordinator.endRun(syncRun)
        await transition.value
        await syncRunCoordinator.endQuiescence()
        let outcome = await maintenance.value

        XCTAssertEqual(outcome, .notAdmitted)
        XCTAssertTrue(conversationExistsInStore(shellID))
        XCTAssertTrue(DataCleanupService.IncrementalCleanupSchedule.isDue(defaults: scheduleDefaults))
    }

    // Revert-check: the `announceCleanupFinished()` call that ends
    // `DataCleanupService.runFullCleanup`. The first initial sync runs it
    // before work that can fail, and a sync that fails posts nothing.
    func testRunFullCleanup_announcesOnce() async {
        let announcements = AnnouncementLog()
        let service = makeService(announceCleanupFinished: { announcements.record(shellExisted: false) })

        await service.runFullCleanup(in: stack.newBackgroundContext())

        XCTAssertEqual(announcements.count, 1)
    }

    // Revert-check: the default value of `announceCleanupFinished` in
    // `DataCleanupService.init`. Production builds the service without the
    // argument, and `ChatViewModel` listens for this name on the default
    // center.
    //
    // HONEST SCOPE: the default center is the process's, so another cleanup
    // running in this process would fulfill the expectation too. Tests in one
    // process run one at a time, and nothing else here runs a cleanup.
    func testRunMaintenanceCleanup_byDefault_postsConversationCleanupFinished() async {
        let posted = expectation(forNotification: .conversationCleanupFinished, object: nil)
        let flags = InMemoryMigrationFlagStore()
        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            conversationMutationSerializer: ConversationRollupMutationSerializer(),
            migrationFlags: flags,
            identityAliasProvider: { _ in [Self.me] },
            maintenanceScheduleDefaults: scheduleDefaults
        )

        _ = await service.runMaintenanceCleanup(in: stack.newBackgroundContext())

        await fulfillment(of: [posted], timeout: 2.0)
    }

    // MARK: - Helpers

    /// Pass 3 (`fixAndMergeIncorrectParticipantHashes`) is the only alias
    /// caller here. Its hook stages a deletion in the maintenance context and
    /// returns no aliases, so pass 3 returns before saving anything itself and
    /// the staged deletion reaches pass 3's hold, whose save is made to fail.
    /// The deletion stands in for whatever a pass staged when its save failed.
    private func makeServiceFailingPassThreeSave(stagingDeletionOf conversationID: UUID) -> DataCleanupService {
        let failNextSave = FailNextHoldSave()
        return makeService(
            serializer: ConversationRollupMutationSerializer(),
            identityAliasProvider: { context in
                await context.perform {
                    let request = Conversation.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
                    for conversation in (try? context.fetch(request)) ?? [] {
                        context.delete(conversation)
                    }
                }
                await failNextSave.arm()
                return []
            },
            saveCleanupHold: { context in
                if await failNextSave.consume() {
                    throw InjectedHoldSaveError()
                }
                try await context.perform {
                    guard context.hasChanges else { return }
                    try context.save()
                }
            }
        )
    }

    /// A service whose runs announce through `announceCleanupFinished`
    /// and nowhere else, with everything else as `makeService` has it.
    private func makeService(
        announceCleanupFinished: @escaping @Sendable () -> Void
    ) -> DataCleanupService {
        let flags = InMemoryMigrationFlagStore()
        flags.set(true, forKey: DataCleanupService.participantSetSplitMigrationKey)
        flags.set(true, forKey: DataCleanupService.rfc2047HeaderTextRepairKey)
        return DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            conversationMutationSerializer: ConversationRollupMutationSerializer(),
            migrationFlags: flags,
            identityAliasProvider: { _ in [Self.me] },
            maintenanceScheduleDefaults: scheduleDefaults,
            announceCleanupFinished: announceCleanupFinished
        )
    }

    private func makeService(
        serializer: ConversationRollupMutationSerializer,
        identityAliasProvider: @escaping @Sendable (NSManagedObjectContext) async -> Set<String>,
        saveCleanupHold: (@Sendable (NSManagedObjectContext) async throws -> Void)? = nil
    ) -> DataCleanupService {
        let flags = InMemoryMigrationFlagStore()
        // Latch the flag-gated migrations so pass 3 is the only alias caller.
        flags.set(true, forKey: DataCleanupService.participantSetSplitMigrationKey)
        flags.set(true, forKey: DataCleanupService.rfc2047HeaderTextRepairKey)
        guard let saveCleanupHold else {
            return DataCleanupService(
                coreDataStack: coreDataStack,
                conversationManager: ConversationManager(currentUserEmail: { Self.me }),
                conversationMutationSerializer: serializer,
                migrationFlags: flags,
                identityAliasProvider: identityAliasProvider,
                maintenanceScheduleDefaults: scheduleDefaults
            )
        }
        return DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            conversationMutationSerializer: serializer,
            migrationFlags: flags,
            identityAliasProvider: identityAliasProvider,
            maintenanceScheduleDefaults: scheduleDefaults,
            saveCleanupHold: saveCleanupHold
        )
    }

    /// Whether work parks behind `coordinator`'s boundary within the
    /// deadline. `waitUntilWorkIsWaiting()` awaited bare never returns when
    /// nothing parks, which is what a maintenance that stopped waiting for
    /// the run looks like: the test must fail on that, not hang.
    private func workIsWaiting(on coordinator: SyncRunCoordinator) async -> Bool {
        let parked = ParkedFlag()
        Task {
            await coordinator.waitUntilWorkIsWaiting()
            parked.set()
        }
        return await waitUntil(timeout: 5) { parked.isSet }
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollIntervalNanoseconds: UInt64 = 5_000_000,
        condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return await condition()
    }

    /// A conversation with a message: no maintenance pass deletes it on its
    /// own, so only a staged deletion leaking past a failed save can.
    private func seedConversationWithMessage() throws -> UUID {
        let context = stack.viewContext
        return try context.performAndWait {
            let conversation = ConversationBuilder().build(in: context)
            _ = MessageBuilder().withId("maintenance-victim-\(UUID().uuidString)")
                .inConversation(conversation)
                .build(in: context)
            try context.save()
            return conversation.id
        }
    }

    /// A message-less, participant-less, unpinned shell: exactly what
    /// `removeEmptyConversations` deletes unless a pending send protects it.
    private func seedEmptyConversationShell() throws -> UUID {
        let context = stack.viewContext
        return try context.performAndWait {
            let shell = ConversationBuilder().build(in: context)
            try context.save()
            return shell.id
        }
    }

    private func conversationExistsInStore(_ id: UUID) -> Bool {
        let context = stack.newBackgroundContext()
        return context.performAndWait { Self.conversationExists(id, in: context) }
    }

    private static func conversationExists(_ id: UUID, in context: NSManagedObjectContext) -> Bool {
        let request = Conversation.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return ((try? context.count(for: request)) ?? 0) > 0
    }
}

/// What a service's `announceCleanupFinished` was called with the store in:
/// one entry for each call.
///
/// `@unchecked Sendable`: every read and write of `entries` is made under
/// `lock`.
private final class AnnouncementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Bool] = []

    func record(shellExisted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(shellExisted)
    }

    var shellExistedAtEach: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var count: Int { shellExistedAtEach.count }
}

/// The kind of the exclusive run that was active each time a pass asked.
private actor RunKindLog {
    private(set) var kinds: [SyncRunKind?] = []

    func record(_ kind: SyncRunKind?) {
        kinds.append(kind)
    }
}

/// Set once work has parked behind a coordinator's boundary.
///
/// `@unchecked Sendable`: every read and write of `flag` is made under
/// `lock`.
private final class ParkedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        defer { lock.unlock() }
        flag = true
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

/// What a maintenance request answered, once it has.
///
/// `@unchecked Sendable`: every read and write of `outcome` is made under
/// `lock`.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: DataCleanupService.DueStoreMaintenanceOutcome?

    func set(_ outcome: DataCleanupService.DueStoreMaintenanceOutcome) {
        lock.lock()
        defer { lock.unlock() }
        self.outcome = outcome
    }

    var value: DataCleanupService.DueStoreMaintenanceOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}

/// Starts one queued gate mutation from inside a maintenance pass and holds
/// that pass until the mutation is enqueued behind it, so the test knows the
/// mutation is waiting on the gate rather than racing for it.
private actor QueuedMutationProbe {
    private var task: Task<Bool, Never>?
    private var isEnqueued = false
    private var enqueuedWaiters: [CheckedContinuation<Void, Never>] = []

    func enqueueOnce(_ operation: @escaping @Sendable () async -> Bool) async {
        guard task == nil else { return }
        task = Task { await operation() }
        guard !isEnqueued else { return }
        await withCheckedContinuation { enqueuedWaiters.append($0) }
    }

    func markEnqueued() {
        isEnqueued = true
        let waiters = enqueuedWaiters
        enqueuedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func result() async -> Bool? {
        await task?.value
    }
}

/// Cancels the registered cleanup task from inside a pass, waiting for the
/// registration if the pass gets there first.
private actor CancellationRelay {
    private var task: Task<Void, Never>?
    private var didCancel = false
    private var registrationWaiters: [CheckedContinuation<Void, Never>] = []

    func register(_ task: Task<Void, Never>) {
        self.task = task
        let waiters = registrationWaiters
        registrationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func cancelOnce() async {
        guard !didCancel else { return }
        didCancel = true
        if task == nil {
            await withCheckedContinuation { registrationWaiters.append($0) }
        }
        task?.cancel()
    }
}

/// Fails exactly one hold save, armed from inside the pass that should fail.
private actor FailNextHoldSave {
    private var isArmed = false

    func arm() {
        isArmed = true
    }

    func consume() -> Bool {
        defer { isArmed = false }
        return isArmed
    }
}

private struct InjectedHoldSaveError: Error {}
