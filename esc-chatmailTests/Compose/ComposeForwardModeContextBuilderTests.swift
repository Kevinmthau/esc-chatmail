import XCTest
@testable import esc_chatmail

@MainActor
final class ComposeForwardModeContextBuilderTests: XCTestCase {
    private func makeTestAuthSession(userEmail: String? = nil) -> AuthSession {
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "ComposeForwardModeContextBuilderTests.\(UUID().uuidString)")!,
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

    func testBuild_extractsForwardContentAndAttachmentContexts() throws {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let context = deps.viewContext
        AttachmentPaths.setupDirectories()

        let conversation = Conversation(context: context)
        conversation.id = UUID()
        conversation.keyHash = UUID().uuidString
        conversation.type = "personal"

        let me = Person(context: context)
        me.id = UUID()
        me.email = "me@example.com"
        me.displayName = "Me"

        let other = Person(context: context)
        other.id = UUID()
        other.email = "friend@example.com"
        other.displayName = "Friend"

        let meParticipant = ConversationParticipant(context: context)
        meParticipant.id = UUID()
        meParticipant.participantRole = .normal
        meParticipant.person = me
        meParticipant.conversation = conversation

        let otherParticipant = ConversationParticipant(context: context)
        otherParticipant.id = UUID()
        otherParticipant.participantRole = .normal
        otherParticipant.person = other
        otherParticipant.conversation = conversation

        let message = MessageBuilder()
            .withId("forward-source-message")
            .withSubject("Original Subject")
            .withSender(email: "friend@example.com", name: "Friend")
            .withBody("Original message body")
            .inConversation(conversation)
            .build(in: context)

        _ = HTMLContentHandler.shared.saveHTML(
            "<html><body><p>Forwarded HTML body</p></body></html>",
            for: message.id
        )

        let regularPath = AttachmentPaths.originalPath(idOrUUID: "forward-regular", ext: "pdf")
        XCTAssertTrue(AttachmentPaths.saveData(Data("regular".utf8), to: regularPath))
        defer { AttachmentPaths.deleteFile(at: regularPath) }

        let inlinePath = AttachmentPaths.originalPath(idOrUUID: "forward-inline", ext: "png")
        XCTAssertTrue(AttachmentPaths.saveData(Data("inline".utf8), to: inlinePath))
        defer { AttachmentPaths.deleteFile(at: inlinePath) }

        let regularAttachment = AttachmentBuilder()
            .withId("attachment-regular")
            .withFilename("report.pdf")
            .withMimeType("application/pdf")
            .withLocalURL(regularPath)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("attachment-inline")
            .withFilename("inline.png")
            .withMimeType("image/png")
            .withLocalURL(inlinePath)
            .withContentId("cid-inline")
            .downloaded()
            .forMessage(message)
            .build(in: context)

        let result = try deps.makeComposeForwardModeContextBuilder().build(message: message)

        XCTAssertEqual(result.id, "forward-source-message")
        XCTAssertEqual(result.initialSubject, "Fwd: Original Subject")
        XCTAssertTrue(result.forwardedPlainTextBody.contains("---------- Forwarded message ---------"))
        XCTAssertTrue(result.forwardedPlainTextBody.contains("Original message body"))
        XCTAssertTrue(result.forwardedPlainTextBody.contains("To: friend@example.com"))
        XCTAssertTrue(result.forwardedHTMLBody?.contains("Forwarded HTML body") == true)
        XCTAssertEqual(result.forwardedInlineAttachmentInfos.count, 1)
        XCTAssertEqual(result.forwardedInlineAttachmentInfos.first?.contentId, "cid-inline")
        XCTAssertEqual(result.forwardedRegularAttachmentObjectURIs, [
            regularAttachment.objectID.uriRepresentation().absoluteString
        ])
    }
}
