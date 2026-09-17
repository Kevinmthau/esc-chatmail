import CoreGraphics
import SwiftUI
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
    func testStoredPropertyNames_stateBackingStorage_reportsDeclaredPropertyName() {
        // Anchors every absence assertion in this suite: if SwiftUI renames
        // @State backing storage again, this fails instead of letting
        // `XCTAssertFalse(names.contains(...))` pass vacuously, as the raw
        // `_name` label checks silently did under Xcode 27.
        // Revert-check: dropping the underscore stripping in
        // storedPropertyNames(of:) makes this fail.
        let names = storedPropertyNames(of: StoredPropertyNamingProbe())

        XCTAssertTrue(names.contains("isShowingSheet"), "Stored properties: \(names.sorted())")
        XCTAssertTrue(names.contains("dismiss"), "Stored properties: \(names.sorted())")
    }

    func testConversationListViewDoesNotStoreMessageDrivenSheetState() {
        let deps = makeDependencies()
        let view = ConversationListView(deps: deps)

        let names = storedPropertyNames(of: view)

        // Revert-check: adding `@State private var selectedMessage: Message?`
        // to ConversationListView makes this fail.
        XCTAssertFalse(names.contains("selectedMessage"))
        XCTAssertFalse(names.contains("showingWebView"))
    }

    func testConversationListViewRendersWithInjectedDependencies() {
        let deps = makeDependencies()
        let host = UIHostingController(rootView: ConversationListView(deps: deps))

        host.loadViewIfNeeded()

        XCTAssertNotNil(host.view)
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

        let names = storedPropertyNames(of: view)

        // HONEST SCOPE: destination routing (openEmailReader, dismissDestination)
        // is pinned by ChatViewModelTests, and the presented-sheet cover by
        // testChatVisibilityRemainsCoveredUntilPresentedSheetFinishesDismissing.
        // No API exposes which presentation state the view stores, so this
        // half needs reflection.
        // Revert-check: adding `@State private var showingWebView = false` to
        // ChatView makes this fail.
        XCTAssertTrue(
            names.contains("presentedSheetDestination"),
            "Stored properties: \(names.sorted())"
        )
        XCTAssertFalse(names.contains("selectedMessage"))
        XCTAssertFalse(names.contains("showingWebView"))
        XCTAssertFalse(names.contains("messageToViewInFull"))
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

    /// Mirror's stored-property labels with leading underscores removed, so a
    /// declared `foo` matches regardless of how its backing storage is named.
    /// Xcode 26's `@State` property wrapper stores `_foo`; Xcode 27's `@State`
    /// macro stores `__foo` (a `LazyState`) and synthesizes `_foo`/`$foo` as
    /// computed accessors, which Mirror never lists. Other property wrappers
    /// (`@StateObject`, `@FocusState`, `@Environment`) still store `_foo`.
    private func storedPropertyNames<T>(of value: T) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap { child in
            child.label.map { String($0.drop { $0 == "_" }) }
        })
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

/// Declares one `@State` and one real property wrapper so
/// `storedPropertyNames(of:)` is checked against both storage naming schemes.
private struct StoredPropertyNamingProbe: View {
    @State private var isShowingSheet = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        EmptyView()
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
