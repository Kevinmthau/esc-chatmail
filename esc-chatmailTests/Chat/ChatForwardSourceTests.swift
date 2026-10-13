import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class ChatForwardSourceTests: XCTestCase {
    func testForward_headersUseMessageRolesAndStoredSenderRatherThanConversationParticipants() {
        let dependencies = makeDependencies()
        let context = dependencies.viewContext
        let conversation = ConversationBuilder().visible().recentlyActive().build(in: context)
        let message = MessageBuilder()
            .withSender(email: "sender@example.com", name: "Original Sender")
            .withBody("Original body")
            .inConversation(conversation)
            .build(in: context)
        addMessageParticipant(email: "sender@example.com", name: "Current Contact Name", kind: .from, to: message, in: context)
        addMessageParticipant(email: "me@example.com", name: "Me", kind: .to, to: message, in: context)
        addMessageParticipant(email: "alpha@example.com", name: "Alpha", kind: .to, to: message, in: context)
        addMessageParticipant(email: "team@example.com", name: "Team", kind: .cc, to: message, in: context)
        addMessageParticipant(email: "hidden@example.com", name: "Hidden", kind: .bcc, to: message, in: context)
        let unrelatedPerson = PersonBuilder()
            .withEmail("unrelated@example.com")
            .withDisplayName("Unrelated")
            .build(in: context)
        let unrelatedParticipant = context.insertTestObject(ConversationParticipant.self)
        unrelatedParticipant.id = UUID()
        unrelatedParticipant.participantRole = .normal
        unrelatedParticipant.person = unrelatedPerson
        unrelatedParticipant.conversation = conversation
        let viewModel = ChatViewModel(conversation: conversation, chatDependencies: dependencies.makeChatDependencies())

        viewModel.setMessageToForward(message)

        guard case .forwardCompose(let forwardContext) = viewModel.destination else {
            return XCTFail("Expected forward compose destination")
        }
        let body = forwardContext.forwardedPlainTextBody
        XCTAssertTrue(body.contains("From: Original Sender <sender@example.com>\n"))
        XCTAssertTrue(body.contains("To: Alpha <alpha@example.com>, Me <me@example.com>\n"))
        XCTAssertTrue(body.contains("Cc: Team <team@example.com>\n"))
        XCTAssertFalse(body.contains("Current Contact Name"))
        XCTAssertFalse(body.contains("unrelated@example.com"))
        XCTAssertFalse(body.contains("hidden@example.com"))
    }

    func testForward_sentMessageKeepsOriginalSenderAliasAndAccountRecipient() {
        let dependencies = makeDependencies()
        let context = dependencies.viewContext
        let conversation = ConversationBuilder().visible().recentlyActive().build(in: context)
        let message = MessageBuilder()
            .fromMe()
            .withSender(email: "alias@example.com", name: "Alias Sender")
            .inConversation(conversation)
            .build(in: context)
        addMessageParticipant(email: "me@example.com", name: "Me", kind: .to, to: message, in: context)
        let viewModel = ChatViewModel(conversation: conversation, chatDependencies: dependencies.makeChatDependencies())

        viewModel.setMessageToForward(message)

        guard case .forwardCompose(let forwardContext) = viewModel.destination else {
            return XCTFail("Expected forward compose destination")
        }
        XCTAssertTrue(forwardContext.forwardedPlainTextBody.contains("From: Alias Sender <alias@example.com>\n"))
        XCTAssertTrue(forwardContext.forwardedPlainTextBody.contains("To: Me <me@example.com>\n"))
    }

    func testForward_missingStoredSenderFallsBackToFromParticipant() {
        let dependencies = makeDependencies()
        let context = dependencies.viewContext
        let conversation = ConversationBuilder().visible().recentlyActive().build(in: context)
        let message = MessageBuilder().inConversation(conversation).build(in: context)
        message.senderEmail = nil
        message.senderName = nil
        addMessageParticipant(email: "sender@example.com", name: "Original Sender", kind: .from, to: message, in: context)
        let viewModel = ChatViewModel(conversation: conversation, chatDependencies: dependencies.makeChatDependencies())

        viewModel.setMessageToForward(message)

        guard case .forwardCompose(let forwardContext) = viewModel.destination else {
            return XCTFail("Expected forward compose destination")
        }
        XCTAssertTrue(forwardContext.forwardedPlainTextBody.contains("From: Original Sender <sender@example.com>\n"))
    }

    func testForward_rawRecipientHeadersPreserveAliasesNamesAndOrder() {
        let dependencies = makeDependencies()
        let context = dependencies.viewContext
        let conversation = ConversationBuilder().visible().recentlyActive().build(in: context)
        let message = MessageBuilder()
            .withSender(email: "sender@example.com", name: "Original Sender")
            .inConversation(conversation)
            .build(in: context)
        message.rawToHeader = "=?utf-8?Q?Original=2C_Name?= <my.name+tag@gmail.com>, Bare.Name+alias@gmail.com"
        message.rawCcHeader = "Original Team <team+original@example.com>"
        addMessageParticipant(email: "myname@gmail.com", name: "New Contact Name", kind: .to, to: message, in: context)
        addMessageParticipant(email: "barename@gmail.com", name: "Invented Name", kind: .to, to: message, in: context)
        addMessageParticipant(email: "team+original@example.com", name: "Renamed Team", kind: .cc, to: message, in: context)
        addMessageParticipant(email: "hidden@example.com", name: "Hidden", kind: .bcc, to: message, in: context)
        let viewModel = ChatViewModel(conversation: conversation, chatDependencies: dependencies.makeChatDependencies())

        viewModel.setMessageToForward(message)

        guard case .forwardCompose(let forwardContext) = viewModel.destination else {
            return XCTFail("Expected forward compose destination")
        }
        let body = forwardContext.forwardedPlainTextBody
        XCTAssertTrue(body.contains("To: \"Original, Name\" <my.name+tag@gmail.com>, Bare.Name+alias@gmail.com\n"))
        XCTAssertTrue(body.contains("Cc: Original Team <team+original@example.com>\n"))
        XCTAssertFalse(body.contains("New Contact Name"))
        XCTAssertFalse(body.contains("Invented Name"))
        XCTAssertFalse(body.contains("Renamed Team"))
        XCTAssertFalse(body.contains("hidden@example.com"))
    }

    func testForward_rawRecipientGroupsPreserveGroupNamesAndEmptyGroups() {
        let dependencies = makeDependencies()
        let context = dependencies.viewContext
        let conversation = ConversationBuilder().visible().recentlyActive().build(in: context)
        let message = MessageBuilder().inConversation(conversation).build(in: context)
        message.rawToHeader = "undisclosed-recipients:;"
        message.rawCcHeader = "Team: Alice <alice@example.com>, Bob <bob@example.com>;"
        let viewModel = ChatViewModel(conversation: conversation, chatDependencies: dependencies.makeChatDependencies())

        viewModel.setMessageToForward(message)

        guard case .forwardCompose(let forwardContext) = viewModel.destination else {
            return XCTFail("Expected forward compose destination")
        }
        XCTAssertTrue(forwardContext.forwardedPlainTextBody.contains("To: undisclosed-recipients:;\n"))
        XCTAssertTrue(forwardContext.forwardedPlainTextBody.contains("Cc: Team: Alice <alice@example.com>, Bob <bob@example.com>;\n"))
    }

    func testForward_explicitEmptyRecipientHeadersDoNotUseSharedContacts() {
        let dependencies = makeDependencies()
        let context = dependencies.viewContext
        let conversation = ConversationBuilder().visible().recentlyActive().build(in: context)
        let message = MessageBuilder().inConversation(conversation).build(in: context)
        message.rawToHeader = ""
        message.rawCcHeader = ""
        addMessageParticipant(email: "stale@example.com", name: "Stale", kind: .to, to: message, in: context)
        addMessageParticipant(email: "stale-cc@example.com", name: "Stale Cc", kind: .cc, to: message, in: context)
        let viewModel = ChatViewModel(conversation: conversation, chatDependencies: dependencies.makeChatDependencies())

        viewModel.setMessageToForward(message)

        guard case .forwardCompose(let forwardContext) = viewModel.destination else {
            return XCTFail("Expected forward compose destination")
        }
        XCTAssertFalse(forwardContext.forwardedPlainTextBody.contains("\nTo:"))
        XCTAssertFalse(forwardContext.forwardedPlainTextBody.contains("\nCc:"))
    }

    func testForward_storedBareSenderDoesNotAcquireSharedContactName() {
        let dependencies = makeDependencies()
        let context = dependencies.viewContext
        let conversation = ConversationBuilder().visible().recentlyActive().build(in: context)
        let message = MessageBuilder()
            .withSender(email: "sender@example.com", name: "")
            .inConversation(conversation)
            .build(in: context)
        message.senderName = nil
        addMessageParticipant(email: "sender@example.com", name: "Later Contact Name", kind: .from, to: message, in: context)
        let viewModel = ChatViewModel(conversation: conversation, chatDependencies: dependencies.makeChatDependencies())

        viewModel.setMessageToForward(message)

        guard case .forwardCompose(let forwardContext) = viewModel.destination else {
            return XCTFail("Expected forward compose destination")
        }
        XCTAssertTrue(forwardContext.forwardedPlainTextBody.contains("From: sender@example.com\n"))
        XCTAssertFalse(forwardContext.forwardedPlainTextBody.contains("Later Contact Name"))
    }

    private func makeDependencies() -> Dependencies {
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "ChatForwardSourceTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = "me@example.com"
        let tokenManager = MockTokenManager()
        return Dependencies(
            authSession: authSession,
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager)
        )
    }

    private func addMessageParticipant(
        email: String,
        name: String,
        kind: ParticipantKind,
        to message: Message,
        in context: NSManagedObjectContext
    ) {
        let person = PersonBuilder().withEmail(email).withDisplayName(name).build(in: context)
        let participant = context.insertTestObject(MessageParticipant.self)
        participant.id = UUID()
        participant.participantKind = kind
        participant.person = person
        participant.message = message
    }
}
