import XCTest
@testable import esc_chatmail

@MainActor
final class OutboundReplyContextBuilderTests: XCTestCase {
    func testBuild_replySnapshotsProduceReplyMetadataAndConversationAnchor() {
        let authSession = makeTestAuthSession(userEmail: "me@example.com")
        let builder = OutboundReplyContextBuilder(
            replyMetadataBuilder: ReplyMetadataBuilder(authSession: authSession)
        )

        let replyContext = builder.build(
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
            optimisticConversation: .existingConversation("x-coredata://conversation/123")
        )

        XCTAssertEqual(replyContext.metadata.recipientEmails, ["friend@example.com"])
        XCTAssertEqual(replyContext.metadata.subject, "Re: Original Subject")
        XCTAssertEqual(replyContext.metadata.threadId, "thread-123")
        XCTAssertEqual(replyContext.metadata.inReplyTo, "<message-1@example.com>")
        XCTAssertEqual(replyContext.metadata.references, ["<older@example.com>", "<message-1@example.com>"])
        XCTAssertEqual(replyContext.metadata.originalMessage?.senderName, "Friend")
        XCTAssertEqual(replyContext.metadata.originalMessage?.senderEmail, "friend@example.com")
        XCTAssertEqual(replyContext.metadata.originalMessage?.body, "Original body")
        XCTAssertEqual(
            replyContext.optimisticConversation?.existingConversationObjectURI,
            "x-coredata://conversation/123"
        )
    }

    private func makeTestAuthSession(userEmail: String? = nil) -> AuthSession {
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "OutboundReplyContextBuilderTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = userEmail
        return authSession
    }
}
