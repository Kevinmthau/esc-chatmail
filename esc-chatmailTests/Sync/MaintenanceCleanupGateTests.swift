import XCTest
import CoreData
@testable import esc_chatmail

/// Pins how the 6-hour store maintenance shares the cleanup-sensitive gate
/// with optimistic-send creation: each pass takes the gate on its own, a
/// mutation queued mid-run lands between two passes, later passes honor what
/// it committed, and the cadence is marked only once the last pass ran.
///
/// The queued mutation is injected from `identityAliasProvider`, which only
/// `fixAndMergeIncorrectParticipantHashes` (pass 4) calls here — the two
/// flag-gated migrations that also call it are latched off — so it runs
/// while pass 4 holds the gate and before `removeEmptyConversations`
/// (pass 5) starts.
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
    // Wrapping all nine passes back in one `performCleanupSensitiveMutation`
    // makes the queued mutation run after `removeEmptyConversations`, so it
    // no longer sees the empty shell and both assertions fail.
    func testRunIncrementalCleanup_mutationQueuedDuringMaintenance_runsBeforeNextPassAndIsHonored() async throws {
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

        await service.runIncrementalCleanup(in: stack.newBackgroundContext())

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
    // `runIncrementalCleanup`. Without the guard the remaining passes run and
    // the cadence is marked, so the empty shell is deleted and `isDue` is false.
    func testRunIncrementalCleanup_cancelledBetweenPasses_stopsAndLeavesCadenceDue() async throws {
        let shellID = try seedEmptyConversationShell()
        let relay = CancellationRelay()
        let service = makeService(serializer: ConversationRollupMutationSerializer()) { _ in
            await relay.cancelOnce()
            return [Self.me]
        }
        let context = stack.newBackgroundContext()
        let run = Task { await service.runIncrementalCleanup(in: context) }
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
    // keeps `runIncrementalCleanup` from marking the cadence. Pass 4
    // stages a deletion and its hold's save fails. Without the rollback the
    // staged deletion survives into the next pass, whose save commits it (by
    // then a reply could have anchored to that conversation); without the
    // outcome check the run marks the cadence although pass 4's work was lost.
    func testRunIncrementalCleanup_passSaveFails_rollsBackStagedDeletionAndLeavesCadenceDue() async throws {
        let victimID = try seedConversationWithMessage()
        let service = makeServiceFailingPassFourSave(stagingDeletionOf: victimID)

        await service.runIncrementalCleanup(in: stack.newBackgroundContext())

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
        let service = makeServiceFailingPassFourSave(stagingDeletionOf: victimID)
        let context = stack.newBackgroundContext()

        let outcome = await service.runMaintenanceCleanup(in: context)

        XCTAssertEqual(outcome, .saveFailed)
        let hasChanges = await context.perform { context.hasChanges }
        XCTAssertFalse(hasChanges, "The failed pass is rolled back, not left staged")
        XCTAssertTrue(conversationExistsInStore(victimID))
    }

    // HONEST SCOPE: pins pre-existing cadence gating, now read from the
    // injected defaults; it guards no new fix and has no revert target.
    func testRunIncrementalCleanup_cadenceNotDue_skipsMaintenancePasses() async throws {
        let shellID = try seedEmptyConversationShell()
        DataCleanupService.IncrementalCleanupSchedule.markRun(defaults: scheduleDefaults)
        let service = makeService(serializer: ConversationRollupMutationSerializer()) { _ in [Self.me] }

        await service.runIncrementalCleanup(in: stack.newBackgroundContext())

        XCTAssertTrue(conversationExistsInStore(shellID), "Maintenance must not run before its cadence is due")
    }

    // MARK: - Helpers

    /// Pass 4 (`fixAndMergeIncorrectParticipantHashes`) is the only alias
    /// caller here. Its hook stages a deletion in the maintenance context and
    /// returns no aliases, so pass 4 returns before saving anything itself and
    /// the staged deletion reaches pass 4's hold, whose save is made to fail.
    /// The deletion stands in for whatever a pass staged when its save failed.
    private func makeServiceFailingPassFourSave(stagingDeletionOf conversationID: UUID) -> DataCleanupService {
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

    private func makeService(
        serializer: ConversationRollupMutationSerializer,
        identityAliasProvider: @escaping @Sendable (NSManagedObjectContext) async -> Set<String>,
        saveCleanupHold: (@Sendable (NSManagedObjectContext) async throws -> Void)? = nil
    ) -> DataCleanupService {
        let flags = InMemoryMigrationFlagStore()
        // Latch the flag-gated migrations so pass 4 is the only alias caller.
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
