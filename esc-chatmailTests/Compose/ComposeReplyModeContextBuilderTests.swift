import XCTest
@testable import esc_chatmail

@MainActor
final class ComposeReplyModeContextBuilderTests: XCTestCase {
    func testBuild_usesProvidedInitialRecipientsAndReplySnapshots() {
        let builder = ComposeReplyModeContextBuilder(
            outboundReplyContextBuilder: OutboundReplyContextBuilder(
                replyMetadataBuilder: ReplyMetadataBuilder(
                    authSession: makeTestAuthSession(userEmail: "me@example.com")
                )
            )
        )
        let conversationReference = ConversationReference(
            persistentStoreURI: URL(string: "x-coredata://conversation/123")!
        )

        let result = builder.build(
            input: .init(
                initialRecipients: [
                    Recipient(email: "friend@example.com", displayName: "Friend")
                ],
                conversation: .init(
                    participantEmails: ["me@example.com", "friend@example.com"],
                    latestThreadId: "thread-123"
                ),
                replyingTo: .init(
                    subject: "Original Subject",
                    threadId: "thread-123",
                    messageId: "<message-1@example.com>",
                    references: ["<older@example.com>"],
                    originalMessage: QuotedMessage(
                        senderName: "Friend",
                        senderEmail: "friend@example.com",
                        date: Date(timeIntervalSince1970: 1_700_000_000),
                        body: "Original body"
                    )
                ),
                optimisticConversation: .existingConversation(conversationReference)
            )
        )

        XCTAssertEqual(result.initialRecipients.map(\.email), ["friend@example.com"])
        XCTAssertEqual(result.initialRecipients.first?.displayName, "Friend")
        XCTAssertEqual(result.outboundRequestContext.metadata.recipientEmails, ["friend@example.com"])
        XCTAssertEqual(result.outboundRequestContext.metadata.subject, "Re: Original Subject")
        XCTAssertEqual(result.outboundRequestContext.metadata.threadId, "thread-123")
        XCTAssertEqual(result.outboundRequestContext.metadata.inReplyTo, "<message-1@example.com>")
        XCTAssertEqual(result.outboundRequestContext.metadata.references, ["<older@example.com>", "<message-1@example.com>"])
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
