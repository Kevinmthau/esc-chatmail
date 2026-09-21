import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class RecoveredReplyValidationTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var account: Account!
    private var conversation: Conversation!
    private var builder: OutboundReplyContextBuilder!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stack = TestCoreDataStack()
        context = stack.makeMainQueueViewContext()
        account = AccountBuilder().withEmail("me@example.com").build(in: context)
        account.sendAsAliasesArray = [primaryAlias, savedAlias]
        conversation = ConversationBuilder().visible().recentlyActive().build(in: context)
        try context.save()
        let auth = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "RecoveredReplyValidationTests.\(UUID().uuidString)")!,
            clearConversationCaches: {}, cleanupDownloads: {}, resetCoreDataStore: {}, clearAttachmentCache: {}
        )
        auth.userEmail = "me@example.com"
        builder = OutboundReplyContextBuilder(
            viewContext: context,
            replyMetadataBuilder: ReplyMetadataBuilder(authSession: auth),
            replyHTMLContentLoader: HTMLContentLoader(contentHandler: HTMLContentHandler(), sanitizer: .shared),
            loadUserAliases: { [] }
        )
    }

    override func tearDown() {
        builder = nil
        context.reset()
        conversation = nil
        account = nil
        context = nil
        stack = nil
        super.tearDown()
    }

    func testSavedSenderRemainsValidAfterDefaultAliasChanges() throws {
        account.sendAsAliasesArray = [
            SendAsAlias(emailAddress: "new-default@example.com", isDefault: true, verificationStatus: "accepted"),
            SendAsAlias(emailAddress: "me@example.com", isPrimary: true, verificationStatus: "accepted"),
            savedAlias
        ]
        XCTAssertNoThrow(try builder.validateRecoveredReply(metadata(), context: replyContext))
    }

    func testRemovedOrUnverifiedSavedAliasCannotFallBackToAnotherSender() {
        for aliases in [
            [primaryAlias],
            [primaryAlias, SendAsAlias(emailAddress: "saved@example.com", verificationStatus: "pending")]
        ] {
            account.sendAsAliasesArray = aliases
            XCTAssertThrowsError(try builder.validateRecoveredReply(metadata(), context: replyContext)) { error in
                guard let sendError = error as? GmailSendService.SendError,
                      case .sendAsAliasUnavailable(let address) = sendError else {
                    return XCTFail("Expected unavailable saved alias, got \(error)")
                }
                XCTAssertEqual(address, "saved@example.com")
            }
        }
    }

    func testDeletedConversationCannotAcceptRecoveredReply() throws {
        let anchor = replyContext
        context.delete(conversation)
        try context.save()
        XCTAssertThrowsError(try builder.validateRecoveredReply(metadata(), context: anchor)) { error in
            guard let sendError = error as? GmailSendService.SendError,
                  case .replyTargetUnavailable = sendError else {
                return XCTFail("Expected unavailable conversation, got \(error)")
            }
        }
    }

    func testDrainedConversationCannotAcceptRecoveredReply() {
        conversation.hidden = true
        conversation.archivedAt = Date()
        conversation.lastMessageDate = nil
        XCTAssertTrue(conversation.isRetainedDrainedShell)
        XCTAssertThrowsError(try builder.validateRecoveredReply(metadata(), context: replyContext)) { error in
            guard let sendError = error as? GmailSendService.SendError,
                  case .replyTargetUnavailable = sendError else {
                return XCTFail("Expected unavailable conversation, got \(error)")
            }
        }
    }

    func testEnvelopeRoundTripKeepsOriginalThreadAndDeferredQuoteAfterConversationChanges() async throws {
        let originalQuote = QuotedMessage(
            senderName: "Original Sender", senderEmail: "original@example.com",
            date: Date(timeIntervalSince1970: 123), body: "Original quoted text",
            deferredOriginalHTML: DeferredReplyQuotedHTML(
                source: .init(messageId: "original-message", bodyStorageURI: "messages/original.html",
                              bodyText: "Original quoted text", senderEmail: "original@example.com", subject: "Original"),
                resolver: ReplyQuotedHTMLResolver { _ in "Unused old resolver" }
            )
        )
        let stored = try JSONDecoder().decode(
            StoredReplyEnvelope.self,
            from: JSONEncoder().encode(StoredReplyEnvelope(metadata(quote: originalQuote)))
        )
        _ = MessageBuilder().withId("newer-message").withThreadId("newer-thread")
            .withSubject("Different subject").withSender(email: "newer@example.com", name: "New Sender")
            .inConversation(conversation).build(in: context)
        let restored = stored.metadata(resolver: ReplyQuotedHTMLResolver { source in
            "<p>\(source.messageId)|\(source.subject ?? "")</p>"
        })
        try builder.validateRecoveredReply(restored, context: replyContext)

        XCTAssertEqual(restored.recipientEmails, ["original@example.com"])
        XCTAssertEqual(restored.fromEmail, "saved@example.com")
        XCTAssertEqual(restored.fromName, "Saved Sender")
        XCTAssertEqual(restored.subject, "Re: Original")
        XCTAssertEqual(restored.threadId, "original-thread")
        XCTAssertEqual(restored.inReplyTo, "<original@example.com>")
        XCTAssertEqual(restored.references, ["<ancestor@example.com>", "<original@example.com>"])
        XCTAssertEqual(restored.originalMessage?.senderName, "Original Sender")
        XCTAssertEqual(restored.originalMessage?.date, Date(timeIntervalSince1970: 123))
        XCTAssertEqual(restored.originalMessage?.body, "Original quoted text")
        XCTAssertNil(restored.originalMessage?.originalHTML)
        let quote = await restored.originalMessage?.resolvingOriginalHTML()
        XCTAssertEqual(quote?.originalHTML, "<p>original-message|Original</p>")
    }

    private var replyContext: OutboundMessageRequest.ReplyContext {
        builder.build(conversationObjectID: conversation.objectID,
                      replyingToMessageObjectID: nil,
                      optimisticConversation: .existingConversation(.init(objectID: conversation.objectID)))
    }

    private var primaryAlias: SendAsAlias {
        .init(emailAddress: "me@example.com", isDefault: true, isPrimary: true, verificationStatus: "accepted")
    }

    private var savedAlias: SendAsAlias {
        .init(emailAddress: "saved@example.com", verificationStatus: "accepted")
    }

    private func metadata(quote: QuotedMessage? = nil) -> OutboundMessageRequest.ReplyMetadata {
        .init(recipientEmails: ["original@example.com"], fromEmail: "saved@example.com", fromName: "Saved Sender",
              subject: "Re: Original", threadId: "original-thread", inReplyTo: "<original@example.com>",
              references: ["<ancestor@example.com>", "<original@example.com>"], originalMessage: quote)
    }
}
