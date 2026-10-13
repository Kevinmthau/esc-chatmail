import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class ForwardSendRecoveryTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var conversation: Conversation!
    private var apiClient: MockGmailAPIClient!
    private var authSession: AuthSession!
    private var service: GmailSendService!
    private var filePaths: [String] = []

    override func setUp() async throws {
        stack = TestCoreDataStack()
        context = stack.makeMainQueueViewContext()
        conversation = ConversationBuilder().visible().recentlyActive().build(in: context)
        try context.save()
        apiClient = MockGmailAPIClient()
        authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "ForwardSendRecoveryTests.\(UUID().uuidString)")!,
            clearConversationCaches: {}, cleanupDownloads: {},
            resetCoreDataStore: {}, clearAttachmentCache: {}
        )
        authSession.userEmail = "sender@example.com"
        service = GmailSendService(viewContext: context, apiClient: apiClient, authSession: authSession)
        AttachmentPaths.setupDirectories()
    }

    override func tearDown() async throws {
        context.reset()
        for path in filePaths { AttachmentPaths.deleteFile(at: path) }
        filePaths = []
        service = nil
        authSession = nil
        apiClient = nil
        conversation = nil
        context = nil
        stack = nil
    }

    func testDefiniteRejectionRecoversForwardIntoComposeWithOwnedInlineAndRegularParts() async throws {
        let regular = try makeAttachment(filename: "notes.txt")
        let inline = try makeAttachment(filename: "photo.png", contentID: "photo@example.com")
        apiClient.sendMessageError = APIError.authenticationError
        let rejected = expectation(description: "forward rejected after admission")

        let submission = try await makeCoordinator().send(
            request(attachments: [regular, inline]),
            reconciliationHooks: .init(onSuccess: nil, onFailure: { _ in rejected.fulfill() })
        )
        let result = try XCTUnwrap(submission)
        await fulfillment(of: [rejected], timeout: 2)
        XCTAssertEqual(apiClient.sendMessageCallCount, 1)
        let sentMIME = try XCTUnwrap(Data(base64UrlEncoded: apiClient.sendMessageCalls.first?.rawMessage ?? ""))
        let mime = String(decoding: sentMIME, as: UTF8.self)
        XCTAssertEqual(mime.components(separatedBy: "Content-ID: <photo@example.com>").count - 1, 1)
        XCTAssertEqual(mime.components(separatedBy: "Content-Disposition: attachment;").count - 1, 1)

        let message = try XCTUnwrap(service.fetchMessageSync(byID: result.optimisticMessageID))
        let recovery = try XCTUnwrap(ChatReplyDraftStore(context: context).forwardRecoveryContext(message, conversation: conversation))
        XCTAssertEqual(recovery.initialRecipientEmails, ["first@example.com", "second@example.com"])
        XCTAssertEqual(recovery.initialSubject, "Fwd: Original subject")
        XCTAssertEqual(recovery.initialBody, "My note")
        XCTAssertEqual(recovery.forwardedPlainTextBody, "Original forwarded text")
        XCTAssertEqual(recovery.forwardedHTMLBody, "<html><body><img src=\"cid:photo@example.com\"></body></html>")
        XCTAssertEqual(recovery.recoveredAttachmentReferences.count, 2)
        XCTAssertEqual(recovery.recoveredMessageID, message.id)
        XCTAssertEqual(Set(message.attachmentsArray.map(\.objectID)), Set([regular.objectID, inline.objectID]))
        XCTAssertEqual(OutboundSendDeliveryState.resolve(for: message), .notSent)
        XCTAssertNil(try ChatReplyDraftStore(context: context).fetch(conversationID: conversation.id))
        // Opening recovery does not consume it; Cancel has nothing to restore.
        XCTAssertNotNil(service.fetchMessageSync(byID: result.optimisticMessageID))
        XCTAssertNotNil(try mutation(result.optimisticMessageID))
    }

    func testColdRecoveryBeforeAdmissionRetainsForwardEnvelopeAndInlineOwnership() async throws {
        let inline = try makeAttachment(filename: "photo.png", contentID: "photo@example.com")
        let handle = try await createForward(attachments: [inline])
        let conversationID = conversation.objectID
        context.reset()
        conversation = try context.existingObject(with: conversationID) as? Conversation
        service.reconcileAbandonedOptimisticSendMutations()

        let message = try XCTUnwrap(service.fetchMessageSync(byID: handle.optimisticMessageID))
        let recovery = try XCTUnwrap(ChatReplyDraftStore(context: context).forwardRecoveryContext(message, conversation: conversation))
        XCTAssertEqual(recovery.initialBody, "My note")
        XCTAssertEqual(recovery.recoveredAttachmentReferences.count, 1)
        XCTAssertEqual(message.attachmentsArray.first?.contentId, "photo@example.com")
        XCTAssertNotNil(AttachmentPaths.loadData(from: message.attachmentsArray.first?.readableLocalURLValue))
        XCTAssertEqual(apiClient.sendMessageCallCount, 0)
    }

    func testPreAdmissionRollbackOfRecoveredForwardPreservesOriginalFailure() async throws {
        let originalAttachment = try makeAttachment(filename: "original.txt")
        let original = try await createForward(attachments: [originalAttachment])
        service.retainDefinitelyUnsentOptimisticMessage(byID: original.optimisticMessageID, fallbackAttachmentReferences: [])
        let copiedAttachment = try makeAttachment(filename: "original.txt")
        let retry = try await createForward(attachments: [copiedAttachment], replacing: original.optimisticMessageID)

        let outcome = service.rollbackOptimisticMessageBeforeTransmission(
            byID: retry.optimisticMessageID,
            fallbackAttachmentReferences: [LocalAttachmentReference(objectID: copiedAttachment.objectID)]
        )

        XCTAssertEqual(outcome, .rolledBack)
        XCTAssertNil(service.fetchMessageSync(byID: retry.optimisticMessageID))
        let retained = try XCTUnwrap(service.fetchMessageSync(byID: original.optimisticMessageID))
        XCTAssertEqual(OutboundSendDeliveryState.resolve(for: retained), .notSent)
        XCTAssertEqual(originalAttachment.message, retained)
        XCTAssertNil(copiedAttachment.message)
        XCTAssertEqual(copiedAttachment.state, .queued)
        XCTAssertNil(try ChatReplyDraftStore(context: context).fetch(conversationID: conversation.id))
    }

    func testAdmissionConsumesOriginalFailureAndRefusesSecondRecoveryAttempt() async throws {
        let original = try await createForward()
        service.retainDefinitelyUnsentOptimisticMessage(byID: original.optimisticMessageID, fallbackAttachmentReferences: [])
        let firstRetry = try await createForward(replacing: original.optimisticMessageID)
        let secondRetry = try await createForward(replacing: original.optimisticMessageID)

        try service.recordRemoteSendAdmission(optimisticMessageID: firstRetry.optimisticMessageID)
        XCTAssertThrowsError(try service.recordRemoteSendAdmission(optimisticMessageID: secondRetry.optimisticMessageID)) { error in
            guard case GmailSendService.SendError.forwardRecoveryUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        context.reset()
        XCTAssertNil(service.fetchMessageSync(byID: original.optimisticMessageID))
        XCTAssertNil(try mutation(original.optimisticMessageID))
        XCTAssertEqual(try mutation(firstRetry.optimisticMessageID)?.remoteCommittedMessageId, OutboundSendRemoteState.inFlightMessageID)
        XCTAssertNil(try mutation(secondRetry.optimisticMessageID)?.remoteCommittedMessageId)
    }

    func testAdmissionSaveFailurePreservesOriginalAndLeavesRetryUnadmitted() async throws {
        let original = try await createForward()
        service.retainDefinitelyUnsentOptimisticMessage(byID: original.optimisticMessageID, fallbackAttachmentReferences: [])
        let retry = try await createForward(replacing: original.optimisticMessageID)
        let retryID = retry.optimisticMessageID
        let observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextWillSave, object: nil, queue: nil
        ) { notification in
            guard let savingContext = notification.object as? NSManagedObjectContext,
                  savingContext.concurrencyType == .privateQueueConcurrencyType,
                  let record = savingContext.updatedObjects.compactMap({ $0 as? OutboundSendMutationRecord })
                    .first(where: { $0.value(forKey: "id") as? String == retryID }) else { return }
            // A required value fails validation in the fresh admission context.
            record.setValue(nil, forKey: "id")
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertThrowsError(try service.recordRemoteSendAdmission(optimisticMessageID: retryID))
        context.reset()
        XCTAssertNotNil(service.fetchMessageSync(byID: original.optimisticMessageID))
        XCTAssertEqual(try mutation(original.optimisticMessageID)?.remoteCommittedMessageId, OutboundSendRemoteState.notSentMessageID)
        XCTAssertNil(try mutation(retryID)?.remoteCommittedMessageId)
    }

    func testRecoveryAdmissionRefusesOriginalWithUnknownDelivery() async throws {
        let original = try await createForward()
        service.retainDefinitelyUnsentOptimisticMessage(byID: original.optimisticMessageID, fallbackAttachmentReferences: [])
        let retry = try await createForward(replacing: original.optimisticMessageID)
        try service.recordAmbiguousRemoteSend(optimisticMessageID: original.optimisticMessageID)

        XCTAssertThrowsError(try service.recordRemoteSendAdmission(optimisticMessageID: retry.optimisticMessageID))
        XCTAssertNotNil(service.fetchMessageSync(byID: original.optimisticMessageID))
        XCTAssertNil(try mutation(retry.optimisticMessageID)?.remoteCommittedMessageId)
    }

    func testRejectedReplacementRemainsRecoverableAsItsOwnForward() async throws {
        let original = try await createForward()
        service.retainDefinitelyUnsentOptimisticMessage(byID: original.optimisticMessageID, fallbackAttachmentReferences: [])
        let retry = try await createForward(replacing: original.optimisticMessageID)
        try service.recordRemoteSendAdmission(optimisticMessageID: retry.optimisticMessageID)
        service.retainDefinitelyUnsentOptimisticMessage(byID: retry.optimisticMessageID, fallbackAttachmentReferences: [])

        let message = try XCTUnwrap(service.fetchMessageSync(byID: retry.optimisticMessageID))
        let recovery = try XCTUnwrap(ChatReplyDraftStore(context: context).forwardRecoveryContext(message, conversation: conversation))
        XCTAssertEqual(recovery.recoveredMessageID, retry.optimisticMessageID)
        XCTAssertEqual(recovery.initialBody, "My note")
        XCTAssertNil(service.fetchMessageSync(byID: original.optimisticMessageID))
        XCTAssertNil(try StoredForwardEnvelope.decode(from: mutation(retry.optimisticMessageID)?.replyEnvelopeData)?.replacingUnsentMessageID)
        let nextRetry = try await createForward(replacing: retry.optimisticMessageID)
        XCTAssertNoThrow(try service.recordRemoteSendAdmission(optimisticMessageID: nextRetry.optimisticMessageID))
    }

    func testColdRecoveredPreAdmissionReplacementConsumesEntireUnsentChain() async throws {
        let original = try await createForward()
        service.retainDefinitelyUnsentOptimisticMessage(byID: original.optimisticMessageID, fallbackAttachmentReferences: [])
        let abandonedRetry = try await createForward(replacing: original.optimisticMessageID)
        let conversationID = conversation.objectID
        context.reset()
        conversation = try context.existingObject(with: conversationID) as? Conversation
        service.reconcileAbandonedOptimisticSendMutations()
        let retry = try await createForward(replacing: abandonedRetry.optimisticMessageID)

        try service.recordRemoteSendAdmission(optimisticMessageID: retry.optimisticMessageID)

        XCTAssertNil(service.fetchMessageSync(byID: original.optimisticMessageID))
        XCTAssertNil(service.fetchMessageSync(byID: abandonedRetry.optimisticMessageID))
        XCTAssertNil(try mutation(original.optimisticMessageID))
        XCTAssertNil(try mutation(abandonedRetry.optimisticMessageID))
        XCTAssertEqual(try mutation(retry.optimisticMessageID)?.remoteCommittedMessageId, OutboundSendRemoteState.inFlightMessageID)
    }

    private func makeCoordinator() -> OutboundMessageCoordinator {
        OutboundMessageCoordinator(
            sendService: service,
            syncPerformer: ForwardRecoverySyncPerformer(),
            messageFormatBuilder: MessageFormatBuilder(authSession: authSession),
            outboundReplyContextBuilder: OutboundReplyContextBuilder(
                viewContext: context,
                replyMetadataBuilder: ReplyMetadataBuilder(authSession: authSession),
                replyHTMLContentLoader: HTMLContentLoader(contentHandler: HTMLContentHandler(), sanitizer: .shared)
            ),
            mutationTracker: OutboundSendMutationTracker(),
            outboundTaskRegistry: OutboundTaskRegistry(admissionOpen: true),
            networkPathMonitor: ForwardRecoveryNetworkMonitor()
        )
    }

    private func request(attachments: [Attachment]) throws -> OutboundMessageRequest {
        let builder = OutboundAttachmentContextBuilder(viewContext: context)
        let regular = try builder.buildSendAttachments(from: attachments.filter { $0.contentId == nil })
        let inline = try builder.buildSendAttachments(from: attachments.filter { $0.contentId != nil })
        return .forward(.init(
            recipientEmails: ["first@example.com", "second@example.com"],
            subject: "Fwd: Original subject", body: "  My note  ", attachments: regular,
            forwardedPlainTextBody: "Original forwarded text",
            forwardedHTMLBody: "<html><body><img src=\"cid:photo@example.com\"></body></html>",
            forwardedInlineAttachmentInfos: inline.map(\.info),
            optimisticConversation: .existingConversation(ConversationReference(objectID: conversation.objectID)),
            inlineAttachments: inline
        ))
    }

    private func createForward(attachments: [Attachment] = [], replacing replacedID: String? = nil) async throws -> OptimisticSendHandle {
        let envelope = StoredForwardEnvelope(
            recipientEmails: ["first@example.com", "second@example.com"], subject: "Fwd: Original subject",
            authoredBody: "My note", forwardedPlainTextBody: "Original forwarded text",
            forwardedHTMLBody: "<html><body><img src=\"cid:photo@example.com\"></body></html>",
            replacingUnsentMessageID: replacedID
        )
        return try await service.createOptimisticMessage(
            to: envelope.recipientEmails,
            body: "My note\n\nOriginal forwarded text", subject: envelope.subject,
            attachments: OutboundAttachmentContextBuilder(viewContext: context).buildSendAttachments(from: attachments),
            optimisticConversation: .existingConversation(ConversationReference(objectID: conversation.objectID)),
            forwardEnvelope: envelope
        )
    }

    private func makeAttachment(filename: String, contentID: String? = nil) throws -> Attachment {
        let id = "local_\(UUID().uuidString)"
        let path = AttachmentPaths.originalPath(idOrUUID: id, ext: (filename as NSString).pathExtension)
        XCTAssertTrue(AttachmentPaths.saveData(Data("File bytes".utf8), to: path))
        filePaths.append(path)
        let attachment = AttachmentBuilder().withId(id).withFilename(filename).withLocalURL(path).build(in: context)
        attachment.contentId = contentID
        return attachment
    }

    private func mutation(_ messageID: String) throws -> OutboundSendMutationRecord? {
        let request = OutboundSendMutationRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", messageID)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
}

@MainActor
private final class ForwardRecoverySyncPerformer: IncrementalSyncPerforming {
    func performIncrementalSync() async throws {}
}

private final class ForwardRecoveryNetworkMonitor: OutboundNetworkPathMonitoring {
    var isPathKnownUnsatisfied: Bool { false }
    func waitUntilPathSatisfied() async throws { try Task.checkCancellation() }
}
