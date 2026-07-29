import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class SendAsReplyFromTests: XCTestCase {
    private var stack: TestCoreDataStack!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
    }

    override func tearDown() {
        stack = nil
        super.tearDown()
    }

    func testProcessMessage_toAliasDeliveredToPrimary_resolvesReplyFromAlias() async throws {
        let message = makeGmailMessage(
            id: "to-alias",
            headers: [
                MessageHeader(name: "Subject", value: "Alias inbound"),
                MessageHeader(name: "From", value: "Jane Example <jane@example.com>"),
                MessageHeader(name: "To", value: "Kevin <alias@customdomain.com>"),
                MessageHeader(name: "Delivered-To", value: "primary@gmail.com"),
                MessageHeader(name: "Message-ID", value: "<to-alias@example.com>")
            ]
        )

        let processed = try await MessageProcessor().processGmailMessage(
            message,
            myAliases: myAliases,
            sendAsAliases: sendAsAliases
        )

        XCTAssertEqual(processed?.headers.deliveredToAddress, "alias@customdomain.com")
        XCTAssertEqual(processed?.headers.replyFromAddress, "alias@customdomain.com")
    }

    func testProcessMessage_multipleRecipients_choosesConfiguredSendAsAlias() async throws {
        let message = makeGmailMessage(
            id: "multiple-recipients",
            headers: [
                MessageHeader(name: "Subject", value: "Group inbound"),
                MessageHeader(name: "From", value: "Jane Example <jane@example.com>"),
                MessageHeader(name: "To", value: "Other <other@example.com>, \"Alias, Kevin\" <alias@customdomain.com>"),
                MessageHeader(name: "Message-ID", value: "<multiple@example.com>")
            ]
        )

        let processed = try await MessageProcessor().processGmailMessage(
            message,
            myAliases: myAliases,
            sendAsAliases: sendAsAliases
        )

        XCTAssertEqual(processed?.headers.replyFromAddress, "alias@customdomain.com")
    }

    func testProcessMessage_forwardingHeadersResolveWhenMatchingSendAsAlias() async throws {
        let message = makeGmailMessage(
            id: "forwarding-header",
            headers: [
                MessageHeader(name: "Subject", value: "Forwarded inbound"),
                MessageHeader(name: "From", value: "Jane Example <jane@example.com>"),
                MessageHeader(name: "To", value: "primary@gmail.com"),
                MessageHeader(name: "Envelope-To", value: "alias@customdomain.com"),
                MessageHeader(name: "Message-ID", value: "<forwarded@example.com>")
            ]
        )

        let processed = try await MessageProcessor().processGmailMessage(
            message,
            myAliases: myAliases,
            sendAsAliases: sendAsAliases
        )

        XCTAssertEqual(processed?.headers.deliveredToAddress, "alias@customdomain.com")
        XCTAssertEqual(processed?.headers.replyFromAddress, "alias@customdomain.com")
    }

    func testProcessMessage_sentFromAliasFallsBackToFromAlias() async throws {
        let message = makeGmailMessage(
            id: "sent-from-alias",
            labelIds: ["SENT"],
            headers: [
                MessageHeader(name: "Subject", value: "Alias reply"),
                MessageHeader(name: "From", value: "Kevin Alias <alias@customdomain.com>"),
                MessageHeader(name: "To", value: "Jane Example <jane@example.com>"),
                MessageHeader(name: "Message-ID", value: "<sent-from-alias@example.com>")
            ]
        )

        let processed = try await MessageProcessor().processGmailMessage(
            message,
            myAliases: myAliases,
            sendAsAliases: sendAsAliases
        )

        XCTAssertEqual(processed?.headers.deliveredToAddress, "alias@customdomain.com")
        XCTAssertEqual(processed?.headers.replyFromAddress, "alias@customdomain.com")
    }

    func testProcessMessage_sentFromAliasWinsOverRecipientAlias() async throws {
        let message = makeGmailMessage(
            id: "sent-from-alias-self-cc",
            labelIds: ["SENT"],
            headers: [
                MessageHeader(name: "Subject", value: "Alias reply with self cc"),
                MessageHeader(name: "From", value: "Kevin Alias <alias@customdomain.com>"),
                MessageHeader(name: "To", value: "Jane Example <jane@example.com>"),
                MessageHeader(name: "Cc", value: "Kevin Primary <primary@gmail.com>"),
                MessageHeader(name: "Message-ID", value: "<sent-from-alias-self-cc@example.com>")
            ]
        )

        let processed = try await MessageProcessor().processGmailMessage(
            message,
            myAliases: myAliases,
            sendAsAliases: sendAsAliases
        )

        XCTAssertEqual(processed?.headers.deliveredToAddress, "alias@customdomain.com")
        XCTAssertEqual(processed?.headers.replyFromAddress, "alias@customdomain.com")
    }

    func testProcessMessage_nonSentFromAliasFallsBackToDefaultAlias() async throws {
        let message = makeGmailMessage(
            id: "non-sent-from-alias",
            labelIds: ["INBOX"],
            headers: [
                MessageHeader(name: "Subject", value: "Inbound from alias"),
                MessageHeader(name: "From", value: "Kevin Alias <alias@customdomain.com>"),
                MessageHeader(name: "To", value: "Jane Example <jane@example.com>"),
                MessageHeader(name: "Message-ID", value: "<non-sent-from-alias@example.com>")
            ]
        )

        let processed = try await MessageProcessor().processGmailMessage(
            message,
            myAliases: myAliases,
            sendAsAliases: sendAsAliases
        )

        XCTAssertEqual(processed?.headers.deliveredToAddress, "primary@gmail.com")
        XCTAssertEqual(processed?.headers.replyFromAddress, "primary@gmail.com")
    }

    func testReplyMetadata_unconfiguredDeliveredToAddressSurfacesSendAsError() async throws {
        let context = stack.viewContext
        let conversation = makeReplyConversation(in: context)
        let account = AccountBuilder()
            .withEmail("primary@gmail.com")
            .build(in: context)
        account.sendAsAliasesArray = [primaryAlias]

        let replyingTo = MessageBuilder()
            .withId("reply-target")
            .withThreadId("thread-1")
            .withSender(email: "jane@example.com", name: "Jane Example")
            .inConversation(conversation)
            .build(in: context)
        replyingTo.deliveredToAddress = "alias@customdomain.com"
        replyingTo.replyFromAddress = "primary@gmail.com"
        try context.obtainPermanentIDs(for: [conversation, replyingTo])

        let builder = makeReplyContextBuilder()

        do {
            _ = try await builder.buildReplyMetadata(
                .init(
                    conversationObjectID: conversation.objectID,
                    replyingToMessageObjectID: replyingTo.objectID,
                    optimisticConversation: .existingConversation(
                        ConversationReference(objectID: conversation.objectID)
                    )
                )
            )
            XCTFail("Expected sendAsAliasUnavailable")
        } catch {
            guard case GmailSendService.SendError.sendAsAliasUnavailable(let address) = error else {
                return XCTFail("Expected sendAsAliasUnavailable, got \(error)")
            }
            XCTAssertEqual(address, "alias@customdomain.com")
        }
    }

    func testReplyMetadata_gmailPlusDeliveredToFallsBackToPrimaryAlias() async throws {
        let context = stack.viewContext
        let conversation = makeReplyConversation(in: context)
        let account = AccountBuilder()
            .withEmail("primary@gmail.com")
            .build(in: context)
        account.sendAsAliasesArray = [primaryAlias]

        let replyingTo = MessageBuilder()
            .withId("gmail-plus-target")
            .withThreadId("thread-gmail-plus")
            .withSender(email: "jane@example.com", name: "Jane Example")
            .inConversation(conversation)
            .build(in: context)
        replyingTo.deliveredToAddress = "pri.mary+shop@gmail.com"
        replyingTo.replyFromAddress = "primary@gmail.com"
        try context.obtainPermanentIDs(for: [conversation, replyingTo])

        let metadata = try await makeReplyContextBuilder().buildReplyMetadata(
            .init(
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: replyingTo.objectID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversation.objectID)
                )
            )
        )

        XCTAssertEqual(metadata.fromEmail, "primary@gmail.com")
    }

    func testSendAsAliasManager_usesLegacyAccountAliasesWhenStoredSendAsAliasesAreMissing() async throws {
        await SendAsAliasManager.shared.invalidate()
        let context = stack.viewContext
        _ = AccountBuilder()
            .withEmail("primary@gmail.com")
            .withAliases(["alias@customdomain.com"])
            .build(in: context)

        let aliases = await SendAsAliasManager.shared.getAliases(from: context)
        await SendAsAliasManager.shared.invalidate()

        XCTAssertEqual(aliases.map(\.emailAddress), ["primary@gmail.com", "alias@customdomain.com"])
        XCTAssertTrue(aliases.allSatisfy(\.isAcceptedForSending))
    }

    func testSendReply_includesSelectedFromAndThreadingHeaders() async throws {
        let apiClient = MockGmailAPIClient()
        let authSession = makeAuthSession()
        let sendService = GmailSendService(
            viewContext: stack.viewContext,
            apiClient: apiClient,
            authSession: authSession
        )

        _ = try await sendService.sendReply(
            to: ["jane@example.com"],
            fromEmail: "alias@customdomain.com",
            fromName: "Kevin Alias",
            body: "Reply body",
            subject: "Re: Original",
            threadId: "thread-123",
            inReplyTo: "<original@example.com>",
            references: ["<older@example.com>", "<original@example.com>"]
        )

        let call = try XCTUnwrap(apiClient.sendMessageCalls.first)
        let rawData = try XCTUnwrap(Data(base64UrlEncoded: call.rawMessage))
        let mime = String(decoding: rawData, as: UTF8.self)

        XCTAssertEqual(call.threadId, "thread-123")
        XCTAssertTrue(mime.contains("From: Kevin Alias <alias@customdomain.com>\r\n"))
        XCTAssertTrue(mime.contains("In-Reply-To: <original@example.com>\r\n"))
        XCTAssertTrue(mime.contains("References: <older@example.com> <original@example.com>\r\n"))
    }

    func testMessagePersister_persistsReplyFromFieldsAndPreservesSenderDisplayName() async throws {
        let context = stack.viewContext
        let message = makeGmailMessage(
            id: "persist-reply-from",
            headers: [
                MessageHeader(name: "Subject", value: "Persistence"),
                MessageHeader(name: "From", value: "Jane Example <jane@example.com>"),
                MessageHeader(name: "To", value: "Kevin <alias@customdomain.com>"),
                MessageHeader(name: "Delivered-To", value: "primary@gmail.com"),
                MessageHeader(name: "Message-ID", value: "<persist@example.com>")
            ]
        )
        let persister = MessagePersister(photoPrefetcher: { _ in })

        try await persister.saveMessage(
            message,
            myAliases: myAliases,
            sendAsAliases: sendAsAliases,
            in: context
        )

        let savedMessage = try XCTUnwrap(fetchMessage(id: "persist-reply-from", in: context))
        XCTAssertEqual(savedMessage.deliveredToAddress, "alias@customdomain.com")
        XCTAssertEqual(savedMessage.replyFromAddress, "alias@customdomain.com")
        XCTAssertEqual(savedMessage.senderName, "Jane Example")
        XCTAssertEqual(savedMessage.senderEmail, "jane@example.com")
    }

    private var primaryAlias: SendAsAlias {
        SendAsAlias(
            emailAddress: "primary@gmail.com",
            displayName: "Kevin Primary",
            isDefault: true,
            isPrimary: true,
            verificationStatus: "accepted"
        )
    }

    private var sendAsAliases: [SendAsAlias] {
        [
            primaryAlias,
            SendAsAlias(
                emailAddress: "alias@customdomain.com",
                displayName: "Kevin Alias",
                verificationStatus: "accepted"
            )
        ]
    }

    private var myAliases: Set<String> {
        Set(["primary@gmail.com", "alias@customdomain.com"].map(EmailNormalizer.normalize))
    }

    private func makeGmailMessage(
        id: String,
        labelIds: [String] = ["INBOX"],
        headers: [MessageHeader]
    ) -> GmailMessage {
        GmailMessage(
            id: id,
            threadId: "thread-\(id)",
            labelIds: labelIds,
            snippet: "Snippet",
            historyId: "history-\(id)",
            internalDate: "1700000000000",
            payload: MessagePart(
                partId: "",
                mimeType: "text/plain",
                filename: nil,
                headers: headers,
                body: MessageBody(
                    size: 4,
                    data: Data("Body".utf8).base64EncodedString(),
                    attachmentId: nil
                ),
                parts: nil
            ),
            sizeEstimate: nil
        )
    }

    private func makeReplyConversation(in context: NSManagedObjectContext) -> Conversation {
        let conversation = ConversationBuilder()
            .withDisplayName("Jane")
            .visible()
            .recentlyActive()
            .build(in: context)

        let friend = PersonBuilder()
            .withEmail("jane@example.com")
            .withDisplayName("Jane Example")
            .build(in: context)

        let participant = context.insertTestObject(ConversationParticipant.self)
        participant.id = UUID()
        participant.person = friend
        participant.participantRole = .normal
        participant.conversation = conversation

        return conversation
    }

    private func makeReplyContextBuilder() -> OutboundReplyContextBuilder {
        OutboundReplyContextBuilder(
            viewContext: stack.viewContext,
            replyMetadataBuilder: ReplyMetadataBuilder(authSession: makeAuthSession()),
            replyHTMLContentLoader: HTMLContentLoader(
                contentHandler: HTMLContentHandler(),
                sanitizer: .shared
            ),
            loadUserAliases: { self.myAliases }
        )
    }

    private func makeAuthSession() -> AuthSession {
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "SendAsReplyFromTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = "primary@gmail.com"
        authSession.userName = "Kevin Primary"
        return authSession
    }

    private func fetchMessage(id: String, in context: NSManagedObjectContext) throws -> Message? {
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
}
