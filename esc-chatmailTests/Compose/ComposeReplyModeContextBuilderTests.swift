import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class ComposeReplyModeContextBuilderTests: XCTestCase {
    func testBuild_usesProvidedInitialRecipientsAndStableReplyIdentifiers() throws {
        let coreDataStack = TestCoreDataStack()
        let builder = ComposeReplyModeContextBuilder(
            outboundReplyContextBuilder: OutboundReplyContextBuilder(
                viewContext: coreDataStack.viewContext,
                replyMetadataBuilder: ReplyMetadataBuilder(
                    authSession: makeTestAuthSession(userEmail: "me@example.com")
                ),
                replyHTMLContentLoader: HTMLContentLoader()
            )
        )
        let context = coreDataStack.viewContext
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: context)
        let replyingTo = MessageBuilder()
            .withId("message-1")
            .inConversation(conversation)
            .build(in: context)
        try context.obtainPermanentIDs(for: [conversation, replyingTo])
        let conversationReference = ConversationReference(
            objectID: conversation.objectID
        )

        let result = builder.build(
            input: .init(
                initialRecipients: [
                    Recipient(email: "friend@example.com", displayName: "Friend")
                ],
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: replyingTo.objectID,
                optimisticConversation: .existingConversation(conversationReference)
            )
        )

        XCTAssertEqual(result.initialRecipients.map(\.email), ["friend@example.com"])
        XCTAssertEqual(result.initialRecipients.first?.displayName, "Friend")
        XCTAssertEqual(result.outboundRequestContext.conversationObjectID, conversation.objectID)
        XCTAssertEqual(result.outboundRequestContext.replyingToMessageObjectID, replyingTo.objectID)
        XCTAssertEqual(result.outboundRequestContext.optimisticConversation?.existingConversationReference, conversationReference)
    }

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
}
