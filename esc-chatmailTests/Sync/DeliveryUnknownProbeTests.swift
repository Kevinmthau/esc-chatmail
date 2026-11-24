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
        XCTAssertEqual(api.listMessagesQueries, [DeliveryUnknownProbePolicy.query(forOptimisticMessageID: "lost-send")])
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
    // requiring `admittedAt`, the quiet period or the ambiguous marker.
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

    func testRun_listFailure_isNoVerdictAndStagesNothing() async throws {
        try seedSend(id: "unknown", admittedAgo: 2 * 60 * 60)
        api.listMessagesError = APIError.serverError(503)

        let outcome = try await makeProbe().run(runStartedAt: runStart, in: context)

        XCTAssertEqual(outcome.unresolved, ["unknown"])
        let staged = try state(of: "unknown", in: context)
        XCTAssertEqual(staged.marker, OutboundSendRemoteState.ambiguousMessageID)
        XCTAssertNil(staged.probedAt)
        let probeContext: NSManagedObjectContext = context
        XCTAssertFalse(probeContext.performAndWait { probeContext.hasChanges })
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
        let message = MessageBuilder().withId(id).fromMe().build(in: context)
        message.messageId = MimeBuilder.messageId(forOptimisticMessageID: id)
        let attachment = AttachmentBuilder().withId("local_\(id)").withFilename("photo.jpg").build(in: context)
        attachment.state = .uploaded
        message.addToAttachments(attachment)
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
