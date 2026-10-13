import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class ForwardRecoveryDraftCleanupTests: XCTestCase {
    func testChangedRecipientRecoveryKeepsNewSourceConversationWithSeparateReplyDraft() async throws {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        defer { context.reset() }
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "ForwardRecoveryDraftCleanupTests.\(UUID().uuidString)")!,
            clearConversationCaches: {}, cleanupDownloads: {},
            resetCoreDataStore: {}, clearAttachmentCache: {}
        )
        authSession.userEmail = "sender@example.com"
        let service = GmailSendService(
            viewContext: context, apiClient: MockGmailAPIClient(), authSession: authSession
        )
        let original = try await createForward(to: "original@example.com", service: service)
        service.retainDefinitelyUnsentOptimisticMessage(
            byID: original.optimisticMessageID, fallbackAttachmentReferences: []
        )
        let source = try XCTUnwrap(service.fetchMessageSync(byID: original.optimisticMessageID)?.conversation)
        let sourceObjectID = source.objectID
        let sourceID = source.id
        let draftAttachment = AttachmentBuilder().withId("local_\(UUID().uuidString)")
            .withFilename("draft-notes.txt").build(in: context)
        try ChatReplyDraftStore(context: context).save(
            .init(text: "A separate reply draft", targetURI: nil, recoveredEnvelope: nil),
            attachments: [draftAttachment], conversationID: sourceID
        )
        let draftAttachmentObjectID = draftAttachment.objectID

        let replacement = try await createForward(
            to: "changed@example.com", replacing: original.optimisticMessageID, service: service
        )
        try service.recordRemoteSendAdmission(optimisticMessageID: replacement.optimisticMessageID)

        context.reset()
        let sourceRequest = Conversation.fetchRequest()
        sourceRequest.predicate = NSPredicate(format: "SELF == %@", sourceObjectID)
        let retainedSource = try XCTUnwrap(context.fetch(sourceRequest).first)
        XCTAssertTrue(retainedSource.messages?.isEmpty ?? true)
        XCTAssertNil(retainedSource.archivedAt)
        XCTAssertFalse(retainedSource.hidden)
        XCTAssertNotNil(retainedSource.lastMessageDate)
        XCTAssertFalse(retainedSource.hasInbox)
        let draft = try XCTUnwrap(ChatReplyDraftStore(context: context).load(conversationID: sourceID))
        XCTAssertEqual(draft.0.text, "A separate reply draft")
        XCTAssertEqual(draft.1.map(\.objectID), [draftAttachmentObjectID])
        XCTAssertNil(service.fetchMessageSync(byID: original.optimisticMessageID))
        let admittedReplacement = try XCTUnwrap(service.fetchMessageSync(byID: replacement.optimisticMessageID))
        XCTAssertNotEqual(admittedReplacement.conversation?.objectID, sourceObjectID)
    }

    private func createForward(
        to recipient: String,
        replacing sourceMessageID: String? = nil,
        service: GmailSendService
    ) async throws -> OptimisticSendHandle {
        let envelope = StoredForwardEnvelope(
            recipientEmails: [recipient], subject: "Fwd: Original subject",
            authoredBody: "My note", forwardedPlainTextBody: "Original forwarded text",
            forwardedHTMLBody: nil, replacingUnsentMessageID: sourceMessageID
        )
        return try await service.createOptimisticMessage(
            to: envelope.recipientEmails, body: "My note\n\nOriginal forwarded text", subject: envelope.subject,
            optimisticConversation: .participantHash(calculateParticipantHash(from: [recipient])),
            forwardEnvelope: envelope
        )
    }
}
