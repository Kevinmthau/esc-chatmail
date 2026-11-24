import CoreData
import XCTest
@testable import esc_chatmail

/// The "Delivery unknown" lookup run against a store: what it asks Gmail, what
/// it stages in the run's context, and what it leaves alone. It must only ever
/// resolve a send, never send one.
final class DeliveryUnknownProbeTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var api: MockGmailAPIClient!
    private let runStart = Date()

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.newBackgroundContext()
        api = MockGmailAPIClient()
    }

    override func tearDown() {
        api = nil
        context = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - Not found

    // Revert-check: fails if `DeliveryUnknownResolution.stageNotSent` stops
    // writing the `notSent` marker or marking the local attachments failed, or
    // if `DeliveryUnknownProbe.run` stops staging it for a `.notFound` verdict.
    func testRun_ambiguousSendGmailHasNoCopyOf_isStagedNotSentWithItsAttachmentsFailed() async throws {
        try seedSend(id: "lost-send", admittedAgo: 2 * 60 * 60)

        let outcome = try await makeProbe().run(runStartedAt: runStart, in: context)

        XCTAssertEqual(outcome.resolvedAsNotSent, ["lost-send"])
        XCTAssertEqual(
            api.searchAllMessagesQueries,
            [DeliveryUnknownProbePolicy.query(forOptimisticMessageID: "lost-send")],
            "Asked through the search that includes Spam and Trash"
        )
        XCTAssertEqual(api.sendMessageCallCount, 0, "Resolving a send never sends it")
        let staged = try state(of: "lost-send", in: context)
        XCTAssertEqual(staged.marker, OutboundSendRemoteState.notSentMessageID)
        XCTAssertEqual(staged.failureReason, DeliveryUnknownResolution.notSentReason)
        XCTAssertEqual(staged.attachmentStates, [.failed])

        // Staged only: the run's save point commits it, or it dies with the run.
        let durable = try state(of: "lost-send", in: stack.newBackgroundContext())
        XCTAssertEqual(durable.marker, OutboundSendRemoteState.ambiguousMessageID)
        XCTAssertEqual(durable.attachmentStates, [.uploaded])
    }

    func testRun_notSentForward_dropsItsConsumedRecoverySource() async throws {
        let envelope = StoredForwardEnvelope(
            recipientEmails: ["to@example.com"], subject: "Fwd", authoredBody: "fyi",
            forwardedPlainTextBody: "original", forwardedHTMLBody: nil,
            replacingUnsentMessageID: "older-attempt", recoverySourceWasConsumed: true
        )
        try seedSend(id: "lost-forward", admittedAgo: 2 * 60 * 60, envelope: try envelope.encoded())

        _ = try await makeProbe().run(runStartedAt: runStart, in: context)

        let probeContext: NSManagedObjectContext = context
        let data = try await probeContext.perform {
            try Self.record(id: "lost-forward", in: probeContext)?.replyEnvelopeData
        }
        let staged = try XCTUnwrap(StoredForwardEnvelope.decode(from: data))
        XCTAssertNil(staged.replacingUnsentMessageID)
        XCTAssertNil(staged.recoverySourceWasConsumed)
    }

    // MARK: - No verdict

    // Revert-check: fails if `DeliveryUnknownProbePolicy.isEligible` stops
    // requiring `admittedAt` or the quiet period. (The in-flight and Not-sent
    // seeds never reach it: the probe's fetch asks for the ambiguous marker.
    // `DeliveryUnknownProbePolicyTests` pins the marker rule.)
    func testRun_legacyRecentInFlightAndNotSentRecords_areNeverLookedUp() async throws {
        try seedSend(id: "legacy", admittedAgo: nil)
        try seedSend(id: "recent", admittedAgo: 10 * 60)
        try seedSend(id: "in-flight", marker: OutboundSendRemoteState.inFlightMessageID, admittedAgo: 5 * 60 * 60)
        try seedSend(id: "not-sent", marker: OutboundSendRemoteState.notSentMessageID, admittedAgo: 5 * 60 * 60)

        let outcome = try await makeProbe().run(runStartedAt: runStart, in: context)

        XCTAssertEqual(outcome, DeliveryUnknownProbe.Outcome())
        XCTAssertEqual(api.listMessagesCallCount, 0)
        XCTAssertEqual(try state(of: "legacy", in: context).marker, OutboundSendRemoteState.ambiguousMessageID)
        XCTAssertEqual(try state(of: "recent", in: context).marker, OutboundSendRemoteState.ambiguousMessageID)
        XCTAssertEqual(try state(of: "in-flight", in: context).marker, OutboundSendRemoteState.inFlightMessageID)
    }

    // Revert-check: fails if `DeliveryUnknownProbe.run` stops stamping
    // `deliveryProbedAt` for a no-verdict lookup: three records whose lookup
    // keeps failing would take every run's lookups and starve the rest.
    func testRun_listFailure_isNoVerdictButSpacesTheNextLookup() async throws {
        try seedSend(id: "unknown", admittedAgo: 2 * 60 * 60)
        api.listMessagesError = APIError.serverError(503)

        let outcome = try await makeProbe().run(runStartedAt: runStart, in: context)

        XCTAssertEqual(outcome.unresolved, ["unknown"])
        let staged = try state(of: "unknown", in: context)
        XCTAssertEqual(staged.marker, OutboundSendRemoteState.ambiguousMessageID)
        XCTAssertEqual(staged.attachmentStates, [.uploaded])
        XCTAssertEqual(staged.probedAt, runStart)
    }

    // A record whose message row is gone must not become Not sent:
    // `retainDefinitelyUnsentOptimisticMessage` never writes that marker for
    // one, and cold recovery would then restore the conversation's pre-send
    // rollup days later.
    // Revert-check: fails if the probe stops stamping `deliveryProbedAt` on
    // such a record, which would then hold the run's lookups for good.
    // HONEST SCOPE: `storeAgreesItWasNotSent` refuses a record without its
    // message before `stageNotSent` is asked, so removing `stageNotSent`'s own
    // missing-message guard leaves this green; it is a second guard.
    func testRun_recordWhoseMessageIsGone_isLeftDeliveryUnknown() async throws {
        try seedSend(id: "orphan", admittedAgo: 2 * 60 * 60)
        let deleteContext = stack.newBackgroundContext()
        try deleteContext.performAndWait {
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id("orphan")
            for message in try deleteContext.fetch(request) { deleteContext.delete(message) }
            try deleteContext.save()
        }

        let outcome = try await makeProbe().run(runStartedAt: runStart, in: context)

        XCTAssertEqual(outcome.unresolved, ["orphan"])
        let probeContext: NSManagedObjectContext = context
        let marker = try await probeContext.perform {
            try Self.record(id: "orphan", in: probeContext)?.remoteCommittedMessageId
        }
        XCTAssertEqual(marker, OutboundSendRemoteState.ambiguousMessageID)
        let probedAt = try await probeContext.perform {
            try Self.record(id: "orphan", in: probeContext)?.deliveryProbedAt
        }
        XCTAssertEqual(probedAt, runStart, "Spaced like any unresolved lookup, or it would starve the rest")
    }

    // MARK: - The store's own witnesses

    // Revert-check: fails if `DeliveryUnknownResolution.storeAgreesItWasNotSent`
    // stops refusing while a sync ledger row recorded since the send exists:
    // that row may be the send's echo, which the history witness cannot see.
    func testRun_ledgerRowSinceTheSend_refusesNotSent() async throws {
        try seedSend(id: "maybe-abandoned-echo", admittedAgo: 2 * 60 * 60)
        try seedLedgerRow(abandonedAgo: 90 * 60)

        let outcome = try await makeProbe().run(runStartedAt: runStart, in: context)

        XCTAssertEqual(outcome.unresolved, ["maybe-abandoned-echo"])
        let staged = try state(of: "maybe-abandoned-echo", in: context)
        XCTAssertEqual(staged.marker, OutboundSendRemoteState.ambiguousMessageID)
        XCTAssertEqual(staged.probedAt, runStart)
    }

    func testRun_ledgerRowFromBeforeTheSend_isNoWitness() async throws {
        try seedSend(id: "lost-send", admittedAgo: 2 * 60 * 60)
        try seedLedgerRow(abandonedAgo: 5 * 60 * 60)

        let outcome = try await makeProbe().run(runStartedAt: runStart, in: context)

        XCTAssertEqual(outcome.resolvedAsNotSent, ["lost-send"])
    }

    // Revert-check: fails if `DeliveryUnknownResolution.storeAgreesItWasNotSent`
    // stops refusing on a message from the user in the send's conversation,
    // dated around the send, without one of the app's Message-IDs: what the
    // echo looks like if Gmail did not keep ours, when the search cannot find
    // it either.
    func testRun_ownMessageAroundTheSendWithoutOurMessageID_refusesNotSent() async throws {
        try seedSend(id: "rewritten", admittedAgo: 2 * 60 * 60)
        try seedOwnMessage(nextTo: "rewritten", id: "gmail-rewritten-echo", sentAgo: 2 * 60 * 60 - 30, messageId: "<CAgmail-rewritten@mail.gmail.com>")

        let outcome = try await makeProbe().run(runStartedAt: runStart, in: context)

        XCTAssertEqual(outcome.unresolved, ["rewritten"])
        XCTAssertEqual(try state(of: "rewritten", in: context).marker, OutboundSendRemoteState.ambiguousMessageID)
    }

    // Revert-check: fails if `DeliveryUnknownResolution.storeAgreesItWasNotSent`
    // stops refusing on a stored row carrying this send's own Message-ID, in
    // any conversation: an echo the persister kept without consuming the
    // record.
    func testRun_storedEchoWithThisSendsMessageIDElsewhere_refusesNotSent() async throws {
        try seedSend(id: "kept-echo", admittedAgo: 2 * 60 * 60)
        try seedSend(id: "unrelated", admittedAgo: nil)
        try seedOwnMessage(
            nextTo: "unrelated",
            id: "gmail-kept-echo",
            sentAgo: 2 * 60 * 60 - 30,
            messageId: MimeBuilder.messageId(forOptimisticMessageID: "kept-echo")
        )

        let outcome = try await makeProbe().run(runStartedAt: runStart, in: context)

        XCTAssertEqual(outcome.unresolved, ["kept-echo"])
        XCTAssertEqual(try state(of: "kept-echo", in: context).marker, OutboundSendRemoteState.ambiguousMessageID)
    }

    // The history witness is the orchestrator's to pass: a terminal slice
    // with no failed fetch. Pinned from source because no test drives the
    // whole orchestrator into the reconciliation phase with a stored record.
    // Revert-check: fails if `IncrementalSyncOrchestrator.performSync` passes
    // anything else for either argument.
    func testOrchestrator_passesTheHistoryWitnessToTheProbeGate() throws {
        let source = try repositorySource("esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift")
        XCTAssertTrue(source.contains("historySliceIsTerminal: historyResult.nextPageToken == nil"))
        XCTAssertTrue(source.contains("hadFetchFailures: fetchResult.hasFailures"))
        XCTAssertTrue(source.contains("allowsExpensiveWork: allowsExpensiveRecovery"))
    }

    func testRun_echoOfAnotherAppSendInTheConversation_isNoWitness() async throws {
        try seedSend(id: "lost-send", admittedAgo: 2 * 60 * 60)
        try seedOwnMessage(
            nextTo: "lost-send",
            id: "gmail-other-send",
            sentAgo: 2 * 60 * 60 - 30,
            messageId: MimeBuilder.messageId(forOptimisticMessageID: "another-send")
        )
        try seedOwnMessage(nextTo: "lost-send", id: "gmail-much-later", sentAgo: 30 * 60, messageId: "<CAlater@mail.gmail.com>")

        let outcome = try await makeProbe().run(runStartedAt: runStart, in: context)

        XCTAssertEqual(outcome.resolvedAsNotSent, ["lost-send"])
    }

    // The production client puts Spam and Trash in the search: a sent copy the
    // user trashed must still count as found.
    // Revert-check: fails if `GmailAPIClient.searchAllMessages` stops sending
    // `includeSpamTrash=true`, or `DeliveryUnknownProbe.run` goes back to
    // `listMessages`, which leaves Spam and Trash out.
    func testRun_productionClient_searchesWithSpamAndTrashIncluded() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.script = [.data(200, Data(#"{"resultSizeEstimate":0}"#.utf8))]
        try seedSend(id: "lost-send", admittedAgo: 2 * 60 * 60)
        let client = GmailAPIClient(
            tokenManager: MockTokenManager(),
            session: StubURLProtocol.makeSession(),
            retryClock: FakeSyncClock()
        )

        let outcome = try await DeliveryUnknownProbe(messageFetcher: MessageFetcher(apiClient: client, clock: FakeSyncClock()))
            .run(runStartedAt: runStart, in: context)

        XCTAssertEqual(outcome.resolvedAsNotSent, ["lost-send"])
        let url = try XCTUnwrap(StubURLProtocol.requestURLs.first)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "includeSpamTrash", value: "true")))
        XCTAssertTrue(items.contains(URLQueryItem(
            name: "q",
            value: DeliveryUnknownProbePolicy.query(forOptimisticMessageID: "lost-send")
        )))
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testRun_emptyPageWithANextPageToken_isNoVerdict() async throws {
        try seedSend(id: "unknown", admittedAgo: 2 * 60 * 60)
        api.listMessagesResponse = MessagesListResponse(messages: [], nextPageToken: "more", resultSizeEstimate: 1)

        let outcome = try await makeProbe().run(runStartedAt: runStart, in: context)

        XCTAssertEqual(outcome.unresolved, ["unknown"])
        XCTAssertEqual(try state(of: "unknown", in: context).marker, OutboundSendRemoteState.ambiguousMessageID)
    }

    // Revert-check: fails if `DeliveryUnknownProbe.run` stops rethrowing an
    // account-scoped failure (it would be read as no verdict and the run would
    // carry on against a revoked account).
    func testRun_accountScopedFailure_abortsTheRunWithoutAVerdict() async throws {
        try seedSend(id: "unknown", admittedAgo: 2 * 60 * 60)
        api.listMessagesError = APIError.authenticationError

        do {
            _ = try await makeProbe().run(runStartedAt: runStart, in: context)
            XCTFail("Expected the run to abort")
        } catch let error as APIError {
            guard case .authenticationError = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(try state(of: "unknown", in: context).marker, OutboundSendRemoteState.ambiguousMessageID)
    }

    // Revert-check: fails only if `DeliveryUnknownProbe.run` loses both of its
    // cancellation guards, the catch's rethrow and the
    // `Task.checkCancellation()` after the lookup (checked by removing both);
    // either one alone still ends the run.
    // HONEST SCOPE: the mock is cancelled inside the lookup, so this cannot
    // see a lookup that returned an answer after the run was cancelled.
    func testRun_cancelledWhileLookingUp_stagesNothing() async throws {
        try seedSend(id: "unknown", admittedAgo: 2 * 60 * 60)
        api.artificialDelay = 0.3
        let probe = makeProbe()
        let runStart = self.runStart
        let probeContext: NSManagedObjectContext = context
        let task = Task { try await probe.run(runStartedAt: runStart, in: probeContext) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(try state(of: "unknown", in: context).marker, OutboundSendRemoteState.ambiguousMessageID)
    }

    // MARK: - Found

    // Revert-check: fails if `DeliveryUnknownProbe.run` stops returning the
    // found IDs or stops stamping `deliveryProbedAt` on a found record.
    func testRun_foundInGmail_returnsTheIDsAndStampsTheRecordWithoutResolvingIt() async throws {
        try seedSend(id: "delivered", admittedAgo: 2 * 60 * 60)
        api.listMessagesResponse = MessagesListResponse(
            messages: [MessageListItem(id: "gmail-delivered", threadId: "thread")],
            nextPageToken: nil,
            resultSizeEstimate: 1
        )

        let outcome = try await makeProbe().run(runStartedAt: runStart, in: context)

        XCTAssertEqual(outcome.foundMessageIDs, ["gmail-delivered"])
        XCTAssertTrue(outcome.resolvedAsNotSent.isEmpty)
        let staged = try state(of: "delivered", in: context)
        XCTAssertEqual(staged.marker, OutboundSendRemoteState.ambiguousMessageID)
        XCTAssertEqual(staged.probedAt, runStart)
    }

    // MARK: - The phase

    // Revert-check: fails if `ReconciliationPhase.execute` runs the probe when
    // `probesDeliveryUnknownSends` is false, or skips it when it is true.
    func testReconciliationPhase_probesOnlyWhenTheRunAllowsIt() async throws {
        try seedSend(id: "lost-send", admittedAgo: 2 * 60 * 60)
        let probeQuery = DeliveryUnknownProbePolicy.query(forOptimisticMessageID: "lost-send")

        _ = try await makePhase().execute(
            input: ReconciliationInput(skipLabelReconciliation: true),
            context: makePhaseContext()
        )
        XCTAssertFalse(api.listMessagesQueries.contains(probeQuery))
        XCTAssertEqual(try state(of: "lost-send", in: context).marker, OutboundSendRemoteState.ambiguousMessageID)

        _ = try await makePhase().execute(
            input: ReconciliationInput(skipLabelReconciliation: true, probesDeliveryUnknownSends: true),
            context: makePhaseContext()
        )
        XCTAssertTrue(api.listMessagesQueries.contains(probeQuery))
        XCTAssertEqual(try state(of: "lost-send", in: context).marker, OutboundSendRemoteState.notSentMessageID)
        XCTAssertEqual(api.sendMessageCallCount, 0)
    }

    // Revert-check: fails if `ReconciliationPhase.execute` stops passing a
    // failed missed-message recovery to the probe as `allowsNotSentVerdict:
    // false`: the message it knows is missing may be the send's echo.
    func testReconciliationPhase_failedMissedMessageRecovery_refusesNotSent() async throws {
        try seedSend(id: "maybe-missed-echo", admittedAgo: 2 * 60 * 60)
        api.listMessagesResponse = MessagesListResponse(
            messages: [MessageListItem(id: "gmail-missed", threadId: "thread")],
            nextPageToken: nil,
            resultSizeEstimate: 1
        )
        api.listMessagesResponsesByQuery[DeliveryUnknownProbePolicy.query(forOptimisticMessageID: "maybe-missed-echo")] =
            MessagesListResponse(messages: [], nextPageToken: nil, resultSizeEstimate: 0)
        api.getMessageErrors["gmail-missed"] = APIError.serverError(503)

        _ = try await makePhase().execute(
            input: ReconciliationInput(skipLabelReconciliation: true, probesDeliveryUnknownSends: true),
            context: makePhaseContext()
        )

        XCTAssertTrue(api.getMessageCalledIds.contains("gmail-missed"), "The missed message was listed and failed")
        XCTAssertTrue(api.searchAllMessagesQueries.contains(DeliveryUnknownProbePolicy.query(forOptimisticMessageID: "maybe-missed-echo")))
        let staged = try state(of: "maybe-missed-echo", in: context)
        XCTAssertEqual(staged.marker, OutboundSendRemoteState.ambiguousMessageID)
        XCTAssertEqual(staged.probedAt, runStart)
    }

    // Revert-check: fails if `ReconciliationPhase.execute` stops handing the
    // probe's found IDs to the persister's fetch.
    func testReconciliationPhase_foundMessage_isFetchedForPersistence() async throws {
        try seedSend(id: "delivered", admittedAgo: 2 * 60 * 60)
        api.listMessagesResponsesByQuery[DeliveryUnknownProbePolicy.query(forOptimisticMessageID: "delivered")] =
            MessagesListResponse(
                messages: [MessageListItem(id: "gmail-delivered", threadId: "thread")],
                nextPageToken: nil,
                resultSizeEstimate: 1
            )

        _ = try await makePhase().execute(
            input: ReconciliationInput(skipLabelReconciliation: true, probesDeliveryUnknownSends: true),
            context: makePhaseContext()
        )

        XCTAssertTrue(api.getMessageCalledIds.contains("gmail-delivered"))
        XCTAssertEqual(try state(of: "delivered", in: context).marker, OutboundSendRemoteState.ambiguousMessageID)
    }

    // MARK: - Helpers

    private func makeProbe() -> DeliveryUnknownProbe {
        DeliveryUnknownProbe(messageFetcher: MessageFetcher(apiClient: api, clock: FakeSyncClock()))
    }

    private func makePhase() -> ReconciliationPhase {
        let fetcher = MessageFetcher(apiClient: api, clock: FakeSyncClock())
        let defaults = UserDefaults(suiteName: "DeliveryUnknownProbeTests-\(UUID().uuidString)")!
        return ReconciliationPhase(
            reconciliation: SyncReconciliation(messageFetcher: fetcher, defaults: defaults),
            messageFetcher: fetcher,
            messagePersister: MessagePersister(
                coreDataStack: CoreDataStack(persistentContainerForTesting: stack.persistentContainer),
                photoPrefetcher: { _ in }
            ),
            defaults: defaults
        )
    }

    private func makePhaseContext() -> SyncPhaseContext {
        SyncPhaseContext(
            coreDataContext: context,
            labelIds: [],
            myAliases: [],
            syncStartTime: runStart,
            progressHandler: { _, _ in },
            failureTracker: .shared
        )
    }

    private func seedSend(
        id: String,
        marker: String? = OutboundSendRemoteState.ambiguousMessageID,
        admittedAgo: TimeInterval?,
        envelope: Data? = nil
    ) throws {
        let seedContext = stack.newBackgroundContext()
        let admittedAt = admittedAgo.map { runStart.addingTimeInterval(-$0) }
        let createdAt = runStart.addingTimeInterval(-6 * 60 * 60)
        try seedContext.performAndWait {
            try Self.insertSend(
                id: id, marker: marker, admittedAt: admittedAt, createdAt: createdAt,
                envelope: envelope, in: seedContext
            )
        }
    }

    private static func insertSend(
        id: String,
        marker: String?,
        admittedAt: Date?,
        createdAt: Date,
        envelope: Data?,
        in context: NSManagedObjectContext
    ) throws {
        let record = OutboundSendMutationRecord(context: context)
        record.id = id
        record.createdAt = createdAt
        record.remoteCommittedMessageId = marker
        record.admittedAt = admittedAt
        record.replyEnvelopeData = envelope
        let conversation = ConversationBuilder().build(in: context)
        conversation.participantHash = "p|\(id)@example.com"
        let message = MessageBuilder().withId(id).fromMe().withDate(createdAt).inConversation(conversation).build(in: context)
        message.messageId = MimeBuilder.messageId(forOptimisticMessageID: id)
        let attachment = AttachmentBuilder().withId("local_\(id)").withFilename("photo.jpg").build(in: context)
        attachment.state = .uploaded
        message.addToAttachments(attachment)
        try context.save()
    }

    private func seedLedgerRow(abandonedAgo: TimeInterval) throws {
        let seedContext = stack.newBackgroundContext()
        let abandonedAt = runStart.addingTimeInterval(-abandonedAgo)
        try seedContext.performAndWait {
            let row = NSEntityDescription.insertNewObject(forEntityName: "AbandonedSyncMessage", into: seedContext)
            row.setValue(UUID(), forKey: "id")
            row.setValue("gmail-unstored-\(UUID().uuidString)", forKey: "gmailMessageId")
            row.setValue(abandonedAt, forKey: "abandonedAt")
            row.setValue("abandoned", forKey: "state")
            try seedContext.save()
        }
    }

    private func seedOwnMessage(nextTo optimisticID: String, id: String, sentAgo: TimeInterval, messageId: String) throws {
        let seedContext = stack.newBackgroundContext()
        let date = runStart.addingTimeInterval(-sentAgo)
        try seedContext.performAndWait {
            try Self.insertOwnMessage(nextTo: optimisticID, id: id, date: date, messageId: messageId, in: seedContext)
        }
    }

    private static func insertOwnMessage(
        nextTo optimisticID: String,
        id: String,
        date: Date,
        messageId: String,
        in context: NSManagedObjectContext
    ) throws {
        let request = Message.fetchRequest()
        request.predicate = MessagePredicates.id(optimisticID)
        guard let conversation = try context.fetch(request).first?.conversation else {
            throw CocoaError(.coderValueNotFound)
        }
        let message = MessageBuilder().withId(id).fromMe().sent().withDate(date).inConversation(conversation).build(in: context)
        message.messageId = messageId
        try context.save()
    }

    private struct StagedState {
        let marker: String?
        let failureReason: String?
        let probedAt: Date?
        let attachmentStates: [Attachment.State]
    }

    private static func record(id: String, in context: NSManagedObjectContext) throws -> OutboundSendMutationRecord? {
        let request = OutboundSendMutationRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        return try context.fetch(request).first
    }

    private func state(of id: String, in context: NSManagedObjectContext) throws -> StagedState {
        try context.performAndWait { try Self.readState(of: id, in: context) }
    }

    private static func readState(of id: String, in context: NSManagedObjectContext) throws -> StagedState {
        guard let record = try record(id: id, in: context) else { throw CocoaError(.coderValueNotFound) }
        let request = Message.fetchRequest()
        request.predicate = MessagePredicates.id(id)
        guard let message = try context.fetch(request).first else { throw CocoaError(.coderValueNotFound) }
        return StagedState(
            marker: record.remoteCommittedMessageId,
            failureReason: record.failureReason,
            probedAt: record.deliveryProbedAt,
            attachmentStates: message.attachmentsArray.map(\.state)
        )
    }
}
