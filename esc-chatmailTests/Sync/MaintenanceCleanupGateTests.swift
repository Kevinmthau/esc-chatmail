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

    private func makeService(
        serializer: ConversationRollupMutationSerializer,
        identityAliasProvider: @escaping @Sendable (NSManagedObjectContext) async -> Set<String>
    ) -> DataCleanupService {
        let flags = InMemoryMigrationFlagStore()
        // Latch the flag-gated migrations so pass 4 is the only alias caller.
        flags.set(true, forKey: DataCleanupService.participantSetSplitMigrationKey)
        flags.set(true, forKey: DataCleanupService.rfc2047HeaderTextRepairKey)
        return DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            conversationMutationSerializer: serializer,
            migrationFlags: flags,
            identityAliasProvider: identityAliasProvider,
            maintenanceScheduleDefaults: scheduleDefaults
        )
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
