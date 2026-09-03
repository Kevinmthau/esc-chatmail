import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class GmailSendServiceOptimisticCreationTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var sendService: GmailSendService!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        sendService = GmailSendService(viewContext: coreDataStack.viewContext)
    }

    override func tearDown() {
        coreDataStack?.resetViewContext()
        sendService = nil
        coreDataStack = nil
        super.tearDown()
    }

    func testCreateOptimisticMessage_newConversationPersistsDurablyWithStableIDs() async throws {
        let context = coreDataStack.viewContext
        let attachmentBuilder = OutboundAttachmentContextBuilder(viewContext: context)
        let attachment = AttachmentBuilder()
            .withId("local_attachment_1")
            .asImage()
            .queued()
            .withLocalURL("Attachments/photo.jpg")
            .withPreviewURL("Previews/photo.jpg")
            .build(in: context)

        let handle = try await sendService.createOptimisticMessage(
            to: ["friend@example.com"],
            body: "hello",
            subject: "Subject",
            attachments: try attachmentBuilder.buildSendAttachments(from: [attachment]),
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail("friend@example.com")])
            )
        )

        XCTAssertFalse(context.hasChanges, "The optimistic graph and recovery record must be durable together.")
        let fetched = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertFalse(fetched.objectID.isTemporaryID)
        XCTAssertEqual(handle.optimisticMessageObjectID, fetched.objectID)

        let conversation = try XCTUnwrap(fetched.conversation)
        XCTAssertFalse(conversation.objectID.isTemporaryID)
        XCTAssertEqual(handle.conversationReference, ConversationReference(objectID: conversation.objectID))

        XCTAssertEqual(fetched.attachmentsArray.compactMap(\.id), ["local_attachment_1"])

        coreDataStack.resetViewContext()
        let durableMessage = try XCTUnwrap(
            sendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )
        XCTAssertEqual(durableMessage.bodyText, "hello")
        XCTAssertEqual(durableMessage.subject, "Subject")
        XCTAssertEqual(durableMessage.attachmentsArray.compactMap(\.id), ["local_attachment_1"])
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 1)
    }

    func testCreateOptimisticMessage_mirrorsSessionSenderIdentityByDefault() async throws {
        let authSession = makeTestAuthSession(
            userEmail: "me@example.com",
            userName: "Me Example"
        )
        let sendService = GmailSendService(
            viewContext: coreDataStack.viewContext,
            authSession: authSession
        )

        let handle = try await sendService.createOptimisticMessage(
            to: ["friend@example.com"],
            body: "hello",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail("friend@example.com")])
            )
        )

        let message = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(message.senderEmail, "me@example.com")
        XCTAssertEqual(message.senderName, "Me Example")
    }

    func testCreateOptimisticMessage_prefersExplicitSenderIdentityOverSession() async throws {
        let authSession = makeTestAuthSession(
            userEmail: "me@example.com",
            userName: "Me Example"
        )
        let sendService = GmailSendService(
            viewContext: coreDataStack.viewContext,
            authSession: authSession
        )

        let handle = try await sendService.createOptimisticMessage(
            to: ["friend@example.com"],
            body: "hello",
            senderEmail: "alias@example.com",
            senderName: "Alias Example",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail("friend@example.com")])
            )
        )

        let message = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(message.senderEmail, "alias@example.com")
        XCTAssertEqual(message.senderName, "Alias Example")
    }

    func testCreateOptimisticMessage_persistsKnownParticipantRowsWithGraph() async throws {
        let authSession = makeTestAuthSession(
            userEmail: "me@example.com",
            userName: "Me Example"
        )
        let sendService = GmailSendService(
            viewContext: coreDataStack.viewContext,
            authSession: authSession
        )

        let handle = try await sendService.createOptimisticMessage(
            to: ["friend@example.com"],
            body: "hello",
            senderEmail: "alias@example.com",
            senderName: "Alias Example",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail("friend@example.com")])
            )
        )

        let message = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(participantSignatures(on: message), [
            "from:alias@example.com",
            "to:friend@example.com"
        ])
        XCTAssertTrue(message.participants?.allSatisfy { !$0.objectID.isTemporaryID } == true)
        XCTAssertTrue(message.participants?.allSatisfy {
            $0.person?.objectID.isTemporaryID == false
        } == true)

        coreDataStack.resetViewContext()
        let durableMessage = try XCTUnwrap(
            sendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )
        XCTAssertEqual(participantSignatures(on: durableMessage), [
            "from:alias@example.com",
            "to:friend@example.com"
        ])
    }

    /// End-to-end pin of the issue-#151 trigger: an optimistic reply whose
    /// From identity round-trips through the real MIME header format must
    /// compare equal when the sent echo is persisted, even for names the
    /// header quotes and escapes — otherwise every send posts a display-info
    /// refresh that resets (and briefly collapses) every visible bubble.
    func testSentEchoMatchingOptimisticIdentityDoesNotPostDisplayInfoChange() async throws {
        let myEmail = "me@example.com"
        let quotedName = "Kevin \"KT\" Thau"
        let authSession = makeTestAuthSession(userEmail: myEmail, userName: quotedName)
        let sendService = GmailSendService(
            viewContext: coreDataStack.viewContext,
            authSession: authSession
        )
        let context = coreDataStack.viewContext

        let handle = try await sendService.createOptimisticMessage(
            to: ["friend@example.com"],
            body: "hello",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail("friend@example.com")])
            )
        )
        try context.save()
        let optimisticMessage = try XCTUnwrap(
            sendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )

        var headers = ProcessedHeaders()
        headers.subject = "Re: Plans"
        headers.from = MimeBuilder.formatFromHeader(email: myEmail, name: quotedName)
        headers.to = [EmailAddress(email: "friend@example.com", displayName: nil)]
        headers.isFromMe = true

        let processedMessage = ProcessedMessage(
            id: optimisticMessage.id,
            gmThreadId: optimisticMessage.gmThreadId,
            snippet: optimisticMessage.snippet,
            cleanedSnippet: optimisticMessage.cleanedSnippet,
            internalDate: optimisticMessage.internalDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: optimisticMessage.bodyText,
            labelIds: ["SENT"],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        let unexpectedNotification = expectation(
            description: "a matching sent echo must not post a self display-info change"
        )
        unexpectedNotification.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: .personDisplayInfoDidChange,
            object: nil,
            queue: nil
        ) { notification in
            if PersonDisplayInfoChangeNotification.emails(from: notification)
                .contains(myEmail) {
                unexpectedNotification.fulfill()
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        let persister = MessagePersister(photoPrefetcher: { _ in })
        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        // Deterministic check: a mismatching identity is STAGED synchronously
        // in the context's userInfo before any save-driven async post.
        let stagedEmails = context.userInfo["personDisplayInfoDidChange.pendingEmails"] as? [String] ?? []
        XCTAssertFalse(
            stagedEmails.contains(myEmail),
            "The sent echo staged a self display-info change: \(stagedEmails)"
        )
        try context.save()
        await fulfillment(of: [unexpectedNotification], timeout: 0.5)
    }

    private func makeTestAuthSession(
        userEmail: String?,
        userName: String?
    ) -> AuthSession {
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(
                suiteName: "GmailSendServiceOptimisticCreationTests.\(UUID().uuidString)"
            )!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = userEmail
        authSession.userName = userName
        return authSession
    }

    private func participantSignatures(on message: Message) -> Set<String> {
        Set((message.participants ?? []).compactMap { participant in
            guard let email = participant.person?.email else { return nil }
            return "\(participant.participantKind.rawValue):\(email)"
        })
    }

    func testCreateOptimisticMessage_populatesChatPreviewTextFromComposedBody() async throws {
        let body = """
        First paragraph.

        Second paragraph.
        Thanks,
        Kevin
        """

        let handle = try await sendService.createOptimisticMessage(
            to: ["friend@example.com"],
            body: body,
            subject: "Subject",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail("friend@example.com")])
            )
        )

        let message = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(message.chatPreviewText, body)
    }

    func testCreateOptimisticMessage_persistsCustomChatPreviewTextSeparatelyFromBody() async throws {
        let body = "Intro line\n\nForwarded plain text"

        let handle = try await sendService.createOptimisticMessage(
            to: ["friend@example.com"],
            body: body,
            subject: "Fwd: Subject",
            chatPreviewText: "Intro line",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail("friend@example.com")])
            )
        )

        let message = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(message.bodyText, body)
        XCTAssertEqual(message.chatPreviewText, "Intro line")
    }

    func testCreateOptimisticMessage_persistsGraphAndMutationRecordAtomically() async throws {
        let context = coreDataStack.viewContext
        let recipient = "durable-record@example.com"

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "pending send",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )

        XCTAssertFalse(context.hasChanges)

        coreDataStack.resetViewContext()

        let durableMessage = try XCTUnwrap(
            sendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )
        XCTAssertEqual(durableMessage.bodyText, "pending send")
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 1)
    }

    func testCreateOptimisticMessage_rollsBackPendingGraphWhenMutationRecordPersistenceFails() async throws {
        let context = MutationRecordPersistenceFailingContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coreDataStack.persistentContainer.persistentStoreCoordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        let failingSendService = GmailSendService(viewContext: context)
        let attachment = AttachmentBuilder()
            .withId("local_record_failure_attachment")
            .asImage()
            .queued()
            .withLocalURL("Attachments/record-failure.jpg")
            .withPreviewURL("Previews/record-failure.jpg")
            .build(in: context)
        let attachmentContexts = try OutboundAttachmentContextBuilder(viewContext: context)
            .buildSendAttachments(from: [attachment])
        context.failMutationRecordPersistence = false
        let recipient = "record-failure@example.com"

        do {
            _ = try await failingSendService.createOptimisticMessage(
                to: [recipient],
                body: "pending send",
                attachments: attachmentContexts,
                optimisticConversation: .participantHash(
                    calculateParticipantHash(from: [normalizedEmail(recipient)])
                )
            )
            XCTFail("Expected optimistic creation to fail")
        } catch let error as GmailSendService.SendError {
            guard case .optimisticCreationFailed = error else {
                return XCTFail("Expected optimisticCreationFailed but got \(error)")
            }
        }

        context.failMutationRecordPersistence = false
        XCTAssertEqual(try messageCount(in: context), 0)
        XCTAssertEqual(try conversationCount(in: context), 0)
        XCTAssertEqual(try attachmentCount(in: context), 1)
        XCTAssertEqual(try messageParticipantCount(in: context), 0)
        XCTAssertNil(attachment.message)
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 0)

        context.failAfterObtainingPermanentIDs = false
        let retryHandle = try await failingSendService.createOptimisticMessage(
            to: [recipient],
            body: "retry send",
            attachments: attachmentContexts,
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )
        let retryMessage = try XCTUnwrap(failingSendService.fetchMessageSync(byID: retryHandle.optimisticMessageID))
        XCTAssertEqual(retryMessage.attachmentsArray.first?.objectID, attachment.objectID)
        XCTAssertEqual(retryMessage.participants?.filter { $0.participantKind == .to }.count, 1)
    }

    func testCreateOptimisticMessage_reactivatesArchivedConversationDurably() async throws {
        let context = coreDataStack.viewContext
        let recipient = "friend@example.com"
        let participantHash = calculateParticipantHash(from: [normalizedEmail(recipient)])

        let archivedConversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .withDisplayName("Archived")
            .archived()
            .build(in: context)
        try coreDataStack.saveViewContext()

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "hello again",
            optimisticConversation: .participantHash(participantHash)
        )

        let message = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        let conversation = try XCTUnwrap(message.conversation)
        XCTAssertEqual(conversation.objectID, archivedConversation.objectID)
        XCTAssertEqual(handle.conversationReference, ConversationReference(objectID: conversation.objectID))
        XCTAssertNil(conversation.archivedAt)
        XCTAssertFalse(context.hasChanges)
    }

    func testCreateOptimisticMessage_withOptimisticConversationReferenceReusesExistingConversation() async throws {
        let context = coreDataStack.viewContext
        let conversation = ConversationBuilder()
            .withDisplayName("Reply Thread")
            .visible()
            .recentlyActive()
            .build(in: context)
        try coreDataStack.saveViewContext()

        let handle = try await sendService.createOptimisticMessage(
            to: ["friend@example.com"],
            body: "anchored reply",
            subject: "Re: Hello",
            threadId: "thread-123",
            optimisticConversation: .existingConversation(ConversationReference(objectID: conversation.objectID))
        )

        let message = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(message.conversation?.objectID, conversation.objectID)
        XCTAssertEqual(handle.conversationReference, ConversationReference(objectID: conversation.objectID))
        XCTAssertEqual(message.gmThreadId, "thread-123")
        XCTAssertFalse(context.hasChanges)
    }

    func testCreateOptimisticMessage_inheritsListIdFromAnchoredConversation() async throws {
        let context = coreDataStack.viewContext
        let conversation = ConversationBuilder()
            .asList()
            .withListId("list.example.com")
            .withDisplayName("Example List")
            .visible()
            .recentlyActive()
            .build(in: context)
        try coreDataStack.saveViewContext()

        let handle = try await sendService.createOptimisticMessage(
            to: ["post@list.example.com"],
            body: "anchored list reply",
            subject: "Re: List topic",
            threadId: "thread-list",
            optimisticConversation: .existingConversation(
                ConversationReference(objectID: conversation.objectID)
            )
        )

        let message = try XCTUnwrap(
            sendService.fetchMessageSync(byID: handle.optimisticMessageID)
        )
        XCTAssertEqual(message.conversation?.objectID, conversation.objectID)
        XCTAssertEqual(message.listId, "list.example.com")
    }

    func testCreateOptimisticMessage_rejectsRetainedDrainedConversationAnchor() async throws {
        let context = coreDataStack.viewContext
        let conversation = ConversationBuilder()
            .asList()
            .withListId("list.example.com")
            .withDisplayName("Moved List")
            .archived()
            .setHidden()
            .build(in: context)
        try coreDataStack.saveViewContext()

        do {
            _ = try await sendService.createOptimisticMessage(
                to: ["post@list.example.com"],
                body: "Must not send",
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversation.objectID)
                )
            )
            XCTFail("Expected replyTargetUnavailable")
        } catch {
            guard case GmailSendService.SendError.replyTargetUnavailable = error else {
                return XCTFail("Expected replyTargetUnavailable, got \(error)")
            }
        }

        XCTAssertEqual(try messageCount(in: context), 0)
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 0)
    }

    func testCreateOptimisticMessage_rejectsDeletedRegisteredConversationAnchor() async throws {
        let context = coreDataStack.viewContext
        let conversation = ConversationBuilder()
            .withDisplayName("Deleted reply target")
            .visible()
            .recentlyActive()
            .build(in: context)
        try coreDataStack.saveViewContext()
        let reference = ConversationReference(objectID: conversation.objectID)

        context.delete(conversation)
        XCTAssertTrue(conversation.isDeleted)
        XCTAssertTrue(
            context.registeredObject(for: conversation.objectID) === conversation,
            "The test must exercise the registered-object resolution path"
        )

        do {
            _ = try await sendService.createOptimisticMessage(
                to: ["friend@example.com"],
                body: "Must not attach to a deleted target",
                optimisticConversation: .existingConversation(reference)
            )
            XCTFail("Expected replyTargetUnavailable")
        } catch {
            guard case GmailSendService.SendError.replyTargetUnavailable = error else {
                return XCTFail("Expected replyTargetUnavailable, got \(error)")
            }
        }

        XCTAssertEqual(try messageCount(in: context), 0)
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 0)
    }

    private func optimisticMutationRecordCount(in context: NSManagedObjectContext) throws -> Int {
        let request = OutboundSendMutationRecord.fetchRequest()
        request.includesPendingChanges = true
        return try context.count(for: request)
    }

    private func messageCount(in context: NSManagedObjectContext) throws -> Int {
        let request = Message.fetchRequest()
        request.includesPendingChanges = true
        return try context.count(for: request)
    }

    private func messageParticipantCount(in context: NSManagedObjectContext) throws -> Int {
        let request = MessageParticipant.fetchRequest()
        request.includesPendingChanges = true
        return try context.count(for: request)
    }

    private func conversationCount(in context: NSManagedObjectContext) throws -> Int {
        let request = Conversation.fetchRequest()
        request.includesPendingChanges = true
        return try context.count(for: request)
    }

    private func attachmentCount(in context: NSManagedObjectContext) throws -> Int {
        let request = Attachment.fetchRequest()
        request.includesPendingChanges = true
        return try context.count(for: request)
    }
}

private final class MutationRecordPersistenceFailingContext: NSManagedObjectContext, @unchecked Sendable {
    var failMutationRecordPersistence = false
    var failAfterObtainingPermanentIDs = true

    override func save() throws {
        if failMutationRecordPersistence {
            throw NSError(
                domain: "GmailSendServiceOptimisticCreationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Injected optimistic transaction failure"]
            )
        }
        try super.save()
    }

    override func obtainPermanentIDs(for objects: [NSManagedObject]) throws {
        try super.obtainPermanentIDs(for: objects)
        if failAfterObtainingPermanentIDs {
            failMutationRecordPersistence = true
        }
    }
}
