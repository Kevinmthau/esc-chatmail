import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class ChatPreviewRepairTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var flags: InMemoryMigrationFlagStore!
    private var handler: HTMLContentHandler!
    private var directory: URL!
    private var syncWaiter: MockForegroundSyncEngine!
    private var accountWork: SyncRunCoordinator!
    private let html = "<div>Keep this reply.</div><div class=\"gmail_signature\">Best,<br>Alex<br>Manager<br>alex@example.com</div>"

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack(storeKind: .sqlite)
        context = stack.viewContext
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
        context = nil
        stack = nil
        super.tearDown()
    }

    // Revert-check: received/HTML eligibility, non-empty assignment, and limited ID-ordered batches.
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
        try context.save()

        let repair = ChatPreviewRepair(htmlContentHandler: handler)
        let background = stack.newBackgroundContext()
        let first = try await repair.prepareBatch(in: background, after: nil, limit: 1)
        XCTAssertEqual(first.lastMessageID, "001")
        XCTAssertEqual(first.changedMessageIDs, ["001"])
        XCTAssertTrue(stack.saveIfNeeded(context: background))
        let second = try await repair.prepareBatch(in: background, after: first.lastMessageID, limit: 2)
        XCTAssertEqual(second.lastMessageID, "005")
        XCTAssertEqual(second.changedMessageIDs, ["005"])
        XCTAssertTrue(stack.saveIfNeeded(context: background))
        let drained = try await repair.prepareBatch(in: background, after: second.lastMessageID, limit: 2)
        XCTAssertTrue(drained.didDrain)

        context.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        XCTAssertEqual(last.chatPreviewText, received.chatPreviewText)
        XCTAssertTrue(received.isUnread)
        XCTAssertEqual(handler.loadHTML(for: "001"), html)
        for preserved in [outgoing, plain, missing] {
            XCTAssertEqual(preserved.chatPreviewText, "Old preview")
        }
    }

    // Revert-check: pending mutations must stop the cursor before their conversation, then resume.
    func testPendingSendDefersWithoutSkippingProtectedMessage() async throws {
        _ = try message("001")
        let protected = try message("002")
        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "pending-send"
        record.createdAt = Date()
        record.conversationId = protected.conversation?.id
        try context.save()
        let repair = ChatPreviewRepair(htmlContentHandler: handler)
        let background = stack.newBackgroundContext()
        let first = try await repair.prepareBatch(in: background, after: nil)
        XCTAssertTrue(first.deferredForPendingSend)
        XCTAssertFalse(first.didDrain)
        XCTAssertEqual(first.lastMessageID, "001")
        XCTAssertEqual(first.changedMessageIDs, ["001"])
        XCTAssertTrue(stack.saveIfNeeded(context: background))
        context.refreshAllObjects()
        XCTAssertEqual(protected.chatPreviewText, "Old preview")
        context.delete(record)
        try context.save()

        let resumed = try await repair.prepareBatch(in: stack.newBackgroundContext(), after: first.lastMessageID)
        XCTAssertFalse(resumed.deferredForPendingSend)
        XCTAssertEqual(resumed.changedMessageIDs, ["002"])
    }

    // Revert-check: checkpoints are only persisted after a successful save; failed work stays rerunnable.
    func testFailedSaveDoesNotAdvanceCursorAndNextCoordinatorResumes() async throws {
        let received = try message("001")
        try context.save()
        var attemptedSave = false
        let failing = coordinator(save: { _ in attemptedSave = true; return false })
        failing.repairPersistedChatPreviews()
        await waitUntil { attemptedSave }
        failing.cancel()
        context.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Old preview")
        XCTAssertNil(flags.string(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCursorKey))
        XCTAssertFalse(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))

        let resumed = coordinator()
        resumed.repairPersistedChatPreviews()
        await waitUntil { self.flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey) }
        context.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        XCTAssertNil(flags.string(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCursorKey))
        withExtendedLifetime((failing, resumed)) {}
    }

    // Revert-check: a persisted cursor survives coordinator recreation and completed versions are skipped.
    func testSavedCursorResumesAndCompletedVersionDoesNotRunAgain() async throws {
        let alreadyProcessed = try message("001")
        let next = try message("002")
        try context.save()
        flags.setString("001", forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCursorKey)
        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await waitUntil { self.flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey) }
        context.refreshAllObjects()
        XCTAssertEqual(alreadyProcessed.chatPreviewText, "Old preview")
        XCTAssertEqual(next.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        let previousWaits = syncWaiter.waitForCurrentSyncToCompleteCalls
        coordinator().repairPersistedChatPreviews()
        XCTAssertEqual(syncWaiter.waitForCurrentSyncToCompleteCalls, previousWaits)
        withExtendedLifetime(repair) {}
    }

    // Revert-check: a request captured before account teardown cannot acquire a lease in the next account.
    func testAccountTransitionWhileWaitingDoesNotWriteOrMarkCompletion() async throws {
        let received = try message("001")
        try context.save()
        let gate = ChatPreviewRepairGate()
        syncWaiter.onWaitForCurrentSyncToComplete = { await gate.wait() }
        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await waitUntil { self.syncWaiter.waitForCurrentSyncToCompleteCalls == 1 }
        await accountWork.beginQuiescence()
        await accountWork.endQuiescence()
        await gate.open()
        // Park the retry separately so the original request cannot hide an
        // unsafe write behind the later successful repair.
        let retryGate = ChatPreviewRepairGate()
        syncWaiter.onWaitForCurrentSyncToComplete = { await retryGate.wait() }
        await waitUntil {
            repair.repairPersistedChatPreviews()
            return self.syncWaiter.waitForCurrentSyncToCompleteCalls > 1
        }
        context.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Old preview")
        XCTAssertFalse(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        syncWaiter.onWaitForCurrentSyncToComplete = nil
        await retryGate.open()
        await waitUntil { self.flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey) }
        context.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        withExtendedLifetime(repair) {}
    }

    private func message(_ id: String, storedHTML: Bool = true) throws -> Message {
        let conversation = ConversationBuilder().build(in: context)
        let message = MessageBuilder().withId(id).inConversation(conversation).build(in: context)
        message.chatPreviewText = "Old preview"
        if storedHTML { message.bodyStorageURI = try XCTUnwrap(handler.saveHTML(html, for: id)).absoluteString }
        return message
    }

    private func coordinator(save: ((NSManagedObjectContext) -> Bool)? = nil) -> ConversationLaunchRepairCoordinator {
        let stack = self.stack!
        return ConversationLaunchRepairCoordinator(
            storage: StorageDependencies(
                viewContext: stack.viewContext,
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
            htmlContentHandler: handler
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Repair did not reach the expected state")
    }
}

private actor ChatPreviewRepairGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
