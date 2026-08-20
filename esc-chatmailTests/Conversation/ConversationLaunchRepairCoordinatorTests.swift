import XCTest
import CoreData
@testable import esc_chatmail

/// Direct coverage for `ConversationLaunchRepairCoordinator`: the launch
/// preview repair's didDrain gate, the `.syncCompleted` re-arm on the
/// injected notification center, the completed-repair latch, and
/// re-runnability after `cancel()`. The VM-level integration sequences
/// (forwarders, combined empty-drain-then-rearm flow) stay pinned by
/// `ConversationNameRefreshMigrationTests`.
@MainActor
final class ConversationLaunchRepairCoordinatorTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var migrationFlags: InMemoryMigrationFlagStore!
    private var notificationCenter: NotificationCenter!
    private var syncWaiter: MockForegroundSyncEngine!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.viewContext
        migrationFlags = InMemoryMigrationFlagStore()
        // Private center: production posts .syncCompleted on .default, so a
        // suite-owned instance keeps concurrent sync tests from re-arming
        // this suite's coordinators (and vice versa).
        notificationCenter = NotificationCenter()
        syncWaiter = MockForegroundSyncEngine()
    }

    override func tearDown() {
        syncWaiter = nil
        notificationCenter = nil
        migrationFlags = nil
        context = nil
        stack = nil
        super.tearDown()
    }

    // Revert-check: the `storeHadConversations || hasObservedSyncCompletionThisLaunch` guard on ConversationLaunchRepairCoordinator.repairMissingConversationPreviews' didDrain branch — without it an empty-store drain marks the repair complete and the re-run poll below never observes a second sync wait.
    func testRepairMissingConversationPreviews_emptyStoreDrain_doesNotMarkCompletionAndStaysArmed() async throws {
        let coordinator = makeCoordinator()

        coordinator.repairMissingConversationPreviews()

        // The task body runs entirely on the main actor, so once a repeat
        // call starts a second run (observed as a second sync wait), the
        // first run has provably exited with both the running guard and the
        // completion latch clear — an empty drain that (wrongly) latched
        // completion would refuse every repeat call and time this wait out.
        await waitUntil {
            coordinator.repairMissingConversationPreviews()
            return self.syncWaiter.waitForCurrentSyncToCompleteCalls >= 2
        }

        XCTAssertFalse(
            migrationFlags.bool(
                forKey: ConversationLaunchRepairCoordinator.conversationPreviewRepairMigrationKey
            )
        )
    }

    // Revert-check: ConversationLaunchRepairCoordinator.bindSyncCompletionRepairRearm subscribing to the injected notificationCenter in init — without the subscription (or with it moved off the injected center) no sweep ever starts and every wait below times out.
    func testRepairMissingConversationPreviews_syncCompletedOnInjectedCenter_runsRepairToCompletion() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let broken = ConversationBuilder()
            .withLastMessageDate(date)
            .visible()
            .build(in: context)
        MessageBuilder()
            .withId("coordinator-rearm-repairs")
            .withDate(date)
            .withSnippet("Recovered by notification sweep")
            .inConversation(broken)
            .build(in: context)
        try context.save()

        // Constructed only — never poked directly. The subscription must be
        // live from init (a sync can finish before the list first appears),
        // so the posted notification is the sole trigger of the sweep.
        let coordinator = makeCoordinator()

        notificationCenter.post(name: .syncCompleted, object: nil)

        await waitUntil { self.syncWaiter.waitForCurrentSyncToCompleteCalls >= 1 }
        await waitUntil {
            try self.fetchConversation(broken.objectID).snippet == "Recovered by notification sweep"
        }
        await waitUntil {
            self.migrationFlags.bool(
                forKey: ConversationLaunchRepairCoordinator.conversationPreviewRepairMigrationKey
            )
        }

        // The waits above never reference the coordinator, so keep it alive
        // (its subscription and task) for their whole duration explicitly.
        withExtendedLifetime(coordinator) {}
    }

    // Revert-check: the `!hasCompletedConversationPreviewRepair` guard in ConversationLaunchRepairCoordinator.repairMissingConversationPreviews — without it the post-completion .syncCompleted starts a second sweep that repairs the later row and bumps the sync-wait count.
    func testRepairMissingConversationPreviews_completedRepairIgnoresLaterSyncCompleted() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let repaired = ConversationBuilder()
            .withLastMessageDate(date)
            .visible()
            .build(in: context)
        MessageBuilder()
            .withId("coordinator-completed-launch")
            .withDate(date)
            .withSnippet("Repaired at launch")
            .inConversation(repaired)
            .build(in: context)
        try context.save()

        let coordinator = makeCoordinator()
        coordinator.runLaunchRepairsIfNeeded()

        await waitUntil {
            try self.fetchConversation(repaired.objectID).snippet == "Repaired at launch"
        }
        await waitUntil {
            self.migrationFlags.bool(
                forKey: ConversationLaunchRepairCoordinator.conversationPreviewRepairMigrationKey
            )
        }
        let waitCallsAfterCompletion = syncWaiter.waitForCurrentSyncToCompleteCalls

        // Breakage that lands after the completed pass waits for next launch.
        let brokenLater = ConversationBuilder()
            .withLastMessageDate(date)
            .visible()
            .build(in: context)
        MessageBuilder()
            .withId("coordinator-post-completion")
            .withDate(date)
            .withSnippet("Landed after completion")
            .inConversation(brokenLater)
            .build(in: context)
        try context.save()

        notificationCenter.post(name: .syncCompleted, object: nil)

        // HONEST SCOPE: a negative has no condition to poll for, so this is a
        // time-bounded window (same shape as the VM-level migration suite's
        // negative). A would-be sweep's very first act is the sync wait, so
        // the unchanged call count is the tighter of the two assertions.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(try fetchConversation(brokenLater.objectID).snippet)
        XCTAssertEqual(syncWaiter.waitForCurrentSyncToCompleteCalls, waitCallsAfterCompletion)

        // The waits and the negative window never reference the coordinator,
        // so keep it (and its subscription) alive for their whole duration.
        withExtendedLifetime(coordinator) {}
    }

    // Revert-check: the repair task's defer clearing isConversationPreviewRepairRunning in ConversationLaunchRepairCoordinator.repairMissingConversationPreviews — without it a cancelled run leaves the running guard latched and the re-run poll below never starts a second sweep.
    func testCancel_whileAwaitingSyncWaiter_leavesRepairRerunnable() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let broken = ConversationBuilder()
            .withLastMessageDate(date)
            .visible()
            .build(in: context)
        MessageBuilder()
            .withId("coordinator-cancel-rerun")
            .withDate(date)
            .withSnippet("Recovered after cancel")
            .inConversation(broken)
            .build(in: context)
        try context.save()

        let gate = AsyncGate()
        syncWaiter.onWaitForCurrentSyncToComplete = { await gate.wait() }
        let coordinator = makeCoordinator()

        coordinator.repairMissingConversationPreviews()
        await waitUntil { self.syncWaiter.waitForCurrentSyncToCompleteCalls >= 1 }

        // Cancel while the run is parked on the sync wait, then release it so
        // the cancelled run can observe the cancellation and exit.
        coordinator.cancel()
        await gate.open()

        // A cancelled run must never complete the repair.
        XCTAssertFalse(
            migrationFlags.bool(
                forKey: ConversationLaunchRepairCoordinator.conversationPreviewRepairMigrationKey
            )
        )

        // Once the cancelled run has exited (running guard cleared), a repeat
        // call starts a fresh sweep — observed as a second sync wait — that
        // now runs to completion against the seeded store.
        syncWaiter.onWaitForCurrentSyncToComplete = nil
        await waitUntil {
            coordinator.repairMissingConversationPreviews()
            return self.syncWaiter.waitForCurrentSyncToCompleteCalls >= 2
        }
        await waitUntil {
            try self.fetchConversation(broken.objectID).snippet == "Recovered after cancel"
        }
        await waitUntil {
            self.migrationFlags.bool(
                forKey: ConversationLaunchRepairCoordinator.conversationPreviewRepairMigrationKey
            )
        }
    }

    private func makeCoordinator() -> ConversationLaunchRepairCoordinator {
        let stack: TestCoreDataStack = self.stack
        return ConversationLaunchRepairCoordinator(
            storage: StorageDependencies(
                viewContext: stack.viewContext,
                makeBackgroundContext: { stack.newBackgroundContext() },
                saveIfNeeded: { stack.saveIfNeeded(context: $0) },
                migrationFlags: migrationFlags,
                personCache: Dependencies.shared.personCache,
                profilePhotoResolver: Dependencies.shared.profilePhotoResolver
            ),
            conversationManager: ConversationManager(currentUserEmail: { "me@example.com" }),
            syncWaiter: syncWaiter,
            notificationCenter: notificationCenter
        )
    }

    private func fetchConversation(
        _ objectID: NSManagedObjectID
    ) throws -> Conversation {
        // The (default) test context does not auto-merge sibling saves;
        // refresh so reads reflect background-context changes persisted to
        // the store.
        let conversation = try XCTUnwrap(context.existingObject(with: objectID) as? Conversation)
        context.refresh(conversation, mergeChanges: false)
        return conversation
    }

    // The preview repair runs at .background priority; on a loaded CI runner
    // its first poll success can take seconds, and a green run exits at the
    // first successful poll anyway, so the deadline is generous. The 50ms
    // interval keeps this MainActor fetch-and-refresh poll from contending
    // with the repair task's own MainActor hops.
    private func waitUntil(
        timeout: TimeInterval = 30.0,
        pollIntervalNanoseconds: UInt64 = 50_000_000,
        condition: @escaping @MainActor () throws -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if (try? condition()) == true {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

/// One-shot gate: parks waiters until `open()` releases them (and every
/// later waiter). Copied shape from `ForegroundSyncCoordinatorTests`.
private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        pendingContinuations.forEach { $0.resume() }
    }
}
