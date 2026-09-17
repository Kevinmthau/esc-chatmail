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
        try context.save()
        flags.set(true, forKey: "chatPreviewRepair.2026-09-09-signature-cleanup-v1")

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        context.refreshAllObjects()

        XCTAssertEqual(received.chatPreviewText, "Keep this reply.\n\nBest,\n\nJane Doe")
        XCTAssertEqual(received.bodyStorageURI, canonicalURL.absoluteString)
        XCTAssertEqual(handler.loadHTML(for: "001"), f12HTML)
        XCTAssertEqual(try Data(contentsOf: canonicalURL), canonicalData)
        let previousWaits = syncWaiter.waitForCurrentSyncToCompleteCalls
        repair.repairPersistedChatPreviews()
        XCTAssertEqual(syncWaiter.waitForCurrentSyncToCompleteCalls, previousWaits)
        withExtendedLifetime(repair) {}
    }

    func testRepeatedFooterVersionRepairsPreviouslyCompletedPreviewWithoutChangingSource() async throws {
        let received = try message("001")
        let source = RepeatedCorporateSignatureFixture.html()
        let canonicalURL = try XCTUnwrap(handler.saveHTML(source, for: "001"))
        received.bodyStorageURI = canonicalURL.absoluteString
        received.chatPreviewText = RepeatedCorporateSignatureFixture.plainText(includeHistory: false)
        let canonicalData = try Data(contentsOf: canonicalURL)
        try context.save()
        flags.set(true, forKey: "chatPreviewRepair.2026-09-10-signature-contact-links-v1")

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        context.refreshAllObjects()

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
        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "pending-send"
        record.createdAt = Date()
        record.conversationId = protected.conversation?.id
        try context.save()
        let repair = ChatPreviewRepair(htmlContentHandler: handler)
        let background = stack.newBackgroundContext()
        let first = try await repair.prepareBatch(in: background, after: nil)
        XCTAssertEqual(first.firstDeferredMessageID, "002")
        XCTAssertFalse(first.didDrain)
        XCTAssertEqual(first.lastMessageID, "003")
        XCTAssertEqual(first.changedMessageIDs, ["001", "003"])
        XCTAssertTrue(stack.saveIfNeeded(context: background))
        context.refreshAllObjects()
        XCTAssertEqual(protected.chatPreviewText, "Old preview")
        XCTAssertEqual(unrelated.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        context.delete(record)
        try context.save()

        let resumed = try await repair.prepareBatch(in: stack.newBackgroundContext(), after: nil, startingAt: first.firstDeferredMessageID)
        XCTAssertNil(resumed.firstDeferredMessageID)
        XCTAssertEqual(resumed.changedMessageIDs, ["002"])
    }

    // Revert-check: deferred records must not starve later IDs or be lost when a sweep drains.
    func testCoordinatorRepairsUnrelatedRowsThenRetriesDeferredConversation() async throws {
        _ = try message("001")
        let protected = try message("002")
        let unrelated = try message("003")
        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "retained-ambiguous-send"
        record.createdAt = Date()
        record.conversationId = protected.conversation?.id
        try context.save()
        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        XCTAssertEqual(
            ChatPreviewRepair.Checkpoint.decode(flags.string(
                forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey
            )).resumeAtMessageID,
            "002"
        )
        context.refreshAllObjects()
        XCTAssertEqual(protected.chatPreviewText, "Old preview")
        XCTAssertEqual(unrelated.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        XCTAssertFalse(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        context.delete(record)
        try context.save()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        context.refreshAllObjects()
        XCTAssertEqual(protected.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        withExtendedLifetime(repair) {}
    }

    // Revert-check: empty derivations never replace a non-empty saved preview.
    func testEmptyHTMLPreservesSavedPreview() async throws {
        let empty = try message("001")
        empty.bodyStorageURI = try XCTUnwrap(handler.saveHTML("<div></div>", for: "001")).absoluteString
        try context.save()
        let background = stack.newBackgroundContext()
        let batch = try await ChatPreviewRepair(htmlContentHandler: handler).prepareBatch(in: background, after: nil)
        XCTAssertTrue(batch.changedMessageIDs.isEmpty)
        XCTAssertEqual(batch.lastMessageID, "001")
        XCTAssertEqual(empty.chatPreviewText, "Old preview")
    }

    // Revert-check: checkpoints are only persisted after a successful save; failed work stays rerunnable.
    func testFailedSaveDoesNotAdvanceCursorAndNextCoordinatorResumes() async throws {
        let received = try message("001")
        try context.save()
        var attemptedSave = false
        let failing = coordinator(save: { _ in attemptedSave = true; return false })
        failing.repairPersistedChatPreviews()
        await failing.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(attemptedSave)
        context.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Old preview")
        XCTAssertNil(flags.string(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey))
        XCTAssertFalse(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))

        let resumed = coordinator()
        resumed.repairPersistedChatPreviews()
        await resumed.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        context.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")
        XCTAssertNil(flags.string(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey))
        withExtendedLifetime((failing, resumed)) {}
    }

    // Revert-check: a persisted cursor survives coordinator recreation and completed versions are skipped.
    func testSavedCursorResumesAndCompletedVersionDoesNotRunAgain() async throws {
        let alreadyProcessed = try message("001")
        let next = try message("002")
        try context.save()
        flags.setString(ChatPreviewRepair.Checkpoint(afterMessageID: "001").encoded,
                        forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey)
        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        context.refreshAllObjects()
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
        try context.save()
        let gate = ChatPreviewRepairGate()
        syncWaiter.onWaitForCurrentSyncToComplete = { await gate.wait() }
        let repair = coordinator()

        await gate.open()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        context.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Keep this reply.\n\nBest,\n\nAlex")

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
        // Join the original worker before checking account isolation so the
        // later retry cannot hide an unsafe write or completion marker.
        await repair.waitForChatPreviewRepairCompletion()
        context.refreshAllObjects()
        XCTAssertEqual(received.chatPreviewText, "Old preview")
        XCTAssertFalse(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        syncWaiter.onWaitForCurrentSyncToComplete = nil
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()
        XCTAssertTrue(flags.bool(forKey: ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey))
        context.refreshAllObjects()
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
        try context.save()

        var bubbleTextBefore: [String: String?] = [:]
        for message in [receivedIDOnlyHTML, receivedWithoutHTML, sentWithHTML, sentWithoutHTML, sentRicherBody, forwarded, whitespacePreview] {
            bubbleTextBefore[message.id] = await bubbleText(for: message)
        }

        try await drainBackfill()
        context.refreshAllObjects()

        // Filled: the stored preview is exactly what the bubble showed.
        for message in [receivedIDOnlyHTML, sentWithHTML, sentWithoutHTML, sentRicherBody, whitespacePreview] {
            let before = try XCTUnwrap(bubbleTextBefore[message.id] ?? nil, "Fixture \(message.id) had no bubble text")
            XCTAssertEqual(message.chatPreviewText, before, "Backfilled preview for \(message.id)")
        }
        XCTAssertEqual(sentRicherBody.chatPreviewText, "Short and then a much longer tail that the HTML lost.")

        // Skipped: the loader still owns these rows.
        XCTAssertNil(receivedWithoutHTML.chatPreviewText, "Received rows without local HTML can still recover over the network")
        XCTAssertNil(forwarded.chatPreviewText, "A stored preview would replace the forwarded lead-in")

        // The bubble is unchanged for every row.
        for message in [receivedIDOnlyHTML, receivedWithoutHTML, sentWithHTML, sentWithoutHTML, sentRicherBody, forwarded, whitespacePreview] {
            let after = await bubbleText(for: message)
            XCTAssertEqual(after, bubbleTextBefore[message.id] ?? nil, "Bubble text changed for \(message.id)")
        }
    }

    // Revert-check: the per-pass loop in `repairPersistedChatPreviews` — a pass
    // that stops early must not block the next one. A retained failed send
    // defers its conversation indefinitely, so gating the backfill on the
    // re-derivation pass completing would strand every blank row.
    func testCoordinatorBackfillCompletesWhileRederivationDefers() async throws {
        let deferredByPendingSend = try message("001")
        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "pending-send"
        record.createdAt = Date()
        record.conversationId = deferredByPendingSend.conversation?.id
        let blankSent = try blankMessage("002", storedHTML: false)
        blankSent.isFromMe = true
        blankSent.bodyText = "Sent body text."
        try context.save()

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()

        context.refreshAllObjects()
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
        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = "pending-send"
        record.createdAt = Date()
        record.conversationId = blank.conversation?.id
        try context.save()

        let repair = coordinator()
        repair.repairPersistedChatPreviews()
        await repair.waitForChatPreviewRepairCompletion()

        context.refreshAllObjects()
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
