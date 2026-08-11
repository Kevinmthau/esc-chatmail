import CoreGraphics
import XCTest
@testable import esc_chatmail

/// Guards the live chat/list surfaces against reintroducing message-driven
/// sheet state (`selectedMessage` + `showingWebView` style), which re-presents
/// sheets when the message object mutates mid-display. Previously targeted
/// VirtualScrollChatView and InboxListView; those views were production-dead
/// and are deleted — ChatView routes presentation through ChatDestination and
/// ConversationListView owns no message-driven sheet state.
@MainActor
final class FullEmailEntryPointPresentationTests: XCTestCase {
    func testConversationListViewDoesNotStoreMessageDrivenSheetState() {
        let deps = makeDependencies()
        let view = ConversationListView(deps: deps)

        let labels = storedPropertyLabels(of: view)

        XCTAssertFalse(labels.contains("_selectedMessage"))
        XCTAssertFalse(labels.contains("_showingWebView"))
    }

    func testChatViewUsesDestinationBasedSheetPresentation() {
        let deps = makeDependencies()
        let conversation = ConversationBuilder()
            .withDisplayName("Live Chat")
            .visible()
            .recentlyActive()
            .build(in: deps.viewContext)
        let view = ChatView(
            conversation: conversation,
            chatDependencies: deps.makeChatDependencies(
                fullEmailOpener: MockEntryPointFullEmailOpener(preparedArtifact: nil)
            )
        )

        let labels = storedPropertyLabels(of: view)

        XCTAssertTrue(labels.contains("_presentedSheetDestination"))
        XCTAssertFalse(labels.contains("_selectedMessage"))
        XCTAssertFalse(labels.contains("_showingWebView"))
        XCTAssertFalse(labels.contains("_messageToViewInFull"))
    }

    func testChatVisibilityRemainsCoveredUntilPresentedSheetFinishesDismissing() {
        XCTAssertFalse(
            ChatView.isChatActiveAndUncovered(
                sceneIsActive: true,
                hasDesiredDestination: false,
                hasPresentedSheet: true,
                hasContactAccessPicker: false,
                hasContactActionAlert: false,
                hasSendErrorAlert: false
            )
        )
        XCTAssertTrue(
            ChatView.isChatActiveAndUncovered(
                sceneIsActive: true,
                hasDesiredDestination: false,
                hasPresentedSheet: false,
                hasContactAccessPicker: false,
                hasContactActionAlert: false,
                hasSendErrorAlert: false
            )
        )
    }

    func testListConversationDoesNotPresentCreationSeededParticipantsAsMembership() {
        XCTAssertFalse(
            ChatView.allowsParticipantListPresentation(conversationType: .list)
        )
        XCTAssertTrue(
            ChatView.allowsParticipantListPresentation(conversationType: .oneToOne)
        )
        XCTAssertTrue(
            ChatView.allowsParticipantListPresentation(conversationType: .group)
        )
    }

    func testChatExitIsBlockedWhileReplySendPreflightOwnsDraft() {
        // Revert-check: removing the isSending gate from
        // ChatView.allowsConversationExit makes this test fail.
        // HONEST SCOPE: XCTest cannot inspect the navigation modifier; this
        // pins the policy shared by the native back gate and action menu.
        XCTAssertFalse(ChatView.allowsConversationExit(isSending: true))
        XCTAssertTrue(ChatView.allowsConversationExit(isSending: false))
    }

    func testChatDismissesOnlyHiddenArchivedConversationWithNoVisibleMessages() {
        let archivedAt = Date()

        XCTAssertTrue(
            ChatView.shouldDismissDrainedConversation(
                hidden: true,
                archivedAt: archivedAt,
                lastMessageDate: nil,
                hasDraft: false,
                isSending: false
            )
        )
        XCTAssertFalse(
            ChatView.shouldDismissDrainedConversation(
                hidden: false,
                archivedAt: archivedAt,
                lastMessageDate: nil,
                hasDraft: false,
                isSending: false
            )
        )
        XCTAssertFalse(
            ChatView.shouldDismissDrainedConversation(
                hidden: true,
                archivedAt: nil,
                lastMessageDate: nil,
                hasDraft: false,
                isSending: false
            )
        )
        XCTAssertFalse(
            ChatView.shouldDismissDrainedConversation(
                hidden: true,
                archivedAt: archivedAt,
                lastMessageDate: Date(),
                hasDraft: false,
                isSending: false
            )
        )
        XCTAssertFalse(
            ChatView.shouldDismissDrainedConversation(
                hidden: true,
                archivedAt: archivedAt,
                lastMessageDate: nil,
                hasDraft: true,
                isSending: false
            )
        )
        XCTAssertFalse(
            ChatView.shouldDismissDrainedConversation(
                hidden: true,
                archivedAt: archivedAt,
                lastMessageDate: nil,
                hasDraft: false,
                isSending: true
            )
        )
    }

    private func storedPropertyLabels<T>(of value: T) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    private func makeDependencies() -> Dependencies {
        let tokenManager = MockTokenManager()
        let authSession = AuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "FullEmailEntryPointPresentationTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        return Dependencies(
            authSession: authSession,
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager)
        )
    }
}

@MainActor
private final class MockEntryPointFullEmailOpener: FullEmailOpening {
    let preparedArtifact: EmailReaderArtifact?

    init(preparedArtifact: EmailReaderArtifact?) {
        self.preparedArtifact = preparedArtifact
    }

    func preparedOpenArtifact(
        request: OriginalEmailWarmRequest,
        message: Message?,
        width: CGFloat?
    ) -> EmailReaderPreparedArtifact? {
        guard let preparedArtifact else {
            return nil
        }
        return EmailReaderPreparedArtifact(
            artifact: preparedArtifact,
            checkoutAvailability: .ready
        )
    }
}
