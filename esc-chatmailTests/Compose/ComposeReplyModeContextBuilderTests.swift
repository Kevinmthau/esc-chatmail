import XCTest
@testable import esc_chatmail

@MainActor
final class ComposeReplyModeContextBuilderTests: XCTestCase {
    private func makeTestAuthSession(userEmail: String? = nil) -> AuthSession {
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "ComposeReplyModeContextBuilderTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = userEmail
        return authSession
    }

    private func makeDependencies(authSession: AuthSession) -> Dependencies {
        let tokenManager = MockTokenManager()
        return Dependencies(
            authSession: authSession,
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager)
        )
    }

    func testBuild_extractsInitialRecipientsAndReplyRequestContext() {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let context = deps.viewContext

        let conversation = ConversationBuilder()
            .withDisplayName("Reply Thread")
            .visible()
            .recentlyActive()
            .build(in: context)

        let other = Person(context: context)
        other.id = UUID()
        other.email = "friend@example.com"
        other.displayName = "Friend"

        let me = Person(context: context)
        me.id = UUID()
        me.email = "me@example.com"
        me.displayName = "Me"

        let otherParticipant = ConversationParticipant(context: context)
        otherParticipant.id = UUID()
        otherParticipant.person = other
        otherParticipant.participantRole = .normal
        otherParticipant.conversation = conversation

        let meParticipant = ConversationParticipant(context: context)
        meParticipant.id = UUID()
        meParticipant.person = me
        meParticipant.participantRole = .normal
        meParticipant.conversation = conversation

        let replyTarget = MessageBuilder()
            .withId("message-1")
            .withSubject("Original Subject")
            .withThreadId("thread-123")
            .withBody("Original body")
            .withSender(email: "friend@example.com", name: "Friend")
            .inConversation(conversation)
            .build(in: context)
        replyTarget.messageId = "<message-1@example.com>"
        replyTarget.references = "<older@example.com>"

        let result = deps.makeComposeReplyModeContextBuilder().build(
            conversation: conversation,
            replyingTo: replyTarget
        )

        XCTAssertEqual(result.initialRecipients.map(\.email), ["friend@example.com"])
        XCTAssertEqual(result.initialRecipients.first?.displayName, "Friend")
        XCTAssertEqual(result.outboundRequestContext.metadata.recipientEmails, ["friend@example.com"])
        XCTAssertEqual(result.outboundRequestContext.metadata.subject, "Re: Original Subject")
        XCTAssertEqual(result.outboundRequestContext.metadata.threadId, "thread-123")
        XCTAssertEqual(result.outboundRequestContext.metadata.inReplyTo, "<message-1@example.com>")
        XCTAssertEqual(result.outboundRequestContext.metadata.references, ["<older@example.com>", "<message-1@example.com>"])
        XCTAssertEqual(
            result.outboundRequestContext.optimisticConversation?.existingConversationObjectURI,
            conversation.objectID.uriRepresentation().absoluteString
        )
    }
}
