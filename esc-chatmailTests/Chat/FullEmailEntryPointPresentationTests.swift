#if os(iOS)
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
            ),
            headerStyle: .navigationTitle,
            bubbleStyle: .standard,
            composerStyle: .bar
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
                windowAppearsActive: true,
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
                windowAppearsActive: true,
                hasDesiredDestination: false,
                hasPresentedSheet: false,
                hasContactAccessPicker: false,
                hasContactActionAlert: false,
                hasSendErrorAlert: false
            )
        )
    }

    /// A Mac chat stays in the window's chat column behind other apps. Mail arriving then must
    /// not be marked read, so an inactive window counts as a covered chat.
    ///
    /// Revert-check: removing `windowAppearsActive &&` from
    /// `ChatView.isChatActiveAndUncovered` makes this fail.
    func testChatVisibility_windowNotActive_isNotActiveAndUncovered() {
        XCTAssertFalse(
            ChatView.isChatActiveAndUncovered(
                sceneIsActive: true,
                windowAppearsActive: false,
                hasDesiredDestination: false,
                hasPresentedSheet: false,
                hasContactAccessPicker: false,
                hasContactActionAlert: false,
                hasSendErrorAlert: false
            )
        )
    }

    /// A mailing list's header opens the sheet as every other chat's does, and the sheet
    /// lists who has written to the list, never its participant rows: those are the people on
    /// the first message filed there, and shown as the list's membership they named whoever
    /// posted first and nobody since. Before, the header of a list opened nothing at all,
    /// which read as a broken tap.
    ///
    /// Revert-check: returning `.participants` for `.list` from
    /// `ParticipantsListPolicy.listing(conversationType:)` makes this fail.
    /// HONEST SCOPE: XCTest cannot tap the navigation title; that the tap is no longer
    /// refused for a list is the removal of `ChatView.allowsParticipantListPresentation`,
    /// which no test can call any more.
    func testParticipantsSheet_mailingList_listsSendersNotCreationSeededParticipantRows() {
        XCTAssertEqual(ParticipantsListPolicy.listing(conversationType: .list), .senders)
        XCTAssertEqual(ParticipantsListPolicy.listing(conversationType: .oneToOne), .participants)
        XCTAssertEqual(ParticipantsListPolicy.listing(conversationType: .group), .participants)
    }

    /// Revert-check: returning "Participants" for `.senders` from
    /// `ParticipantsListPolicy.title(for:)` makes this fail: the sheet would call a list's
    /// senders its participants.
    func testParticipantsSheetTitle_mailingList_doesNotCallSendersParticipants() {
        XCTAssertEqual(ParticipantsListPolicy.title(for: .participants), "Participants")
        XCTAssertEqual(ParticipantsListPolicy.title(for: .senders), "Senders")
    }

    /// A list's senders are resolved a batch at a time, and a sheet filling for the first
    /// time draws those resolved so far: it shows nothing the resolve has not reached.
    ///
    /// Revert-check: returning `shown` from `ParticipantsListPolicy.sendersToDraw` makes
    /// this fail: the sheet stays empty, or at its first batch, until the last sender.
    func testParticipantsSheet_fillingForTheFirstTime_drawsTheSendersResolvedSoFar() {
        let firstBatch = [senderRow("ada"), senderRow("bob")]
        let secondBatch = firstBatch + [senderRow("cy"), senderRow("dee")]

        XCTAssertEqual(sendersToDraw(resolvedSoFar: firstBatch, shown: []), firstBatch)
        XCTAssertEqual(sendersToDraw(resolvedSoFar: secondBatch, shown: firstBatch), secondBatch)
    }

    /// A sheet that has rows is resolving again after a change in Contacts. Its rows are
    /// replaced from the top as they are resolved, and the rows the resolve has not reached
    /// stay, whether the earlier resolve listed everyone or was itself cut short.
    ///
    /// Revert-check: returning `resolvedSoFar` alone from
    /// `ParticipantsListPolicy.sendersToDraw` makes this fail: the list is cut back to its
    /// first batch. So does drawing the senders resolved so far only where they are more
    /// rows than the sheet shows, as the rule before did (`guard resolvedSoFar.count >
    /// shown.count else { return shown }`): Bob is then still shown as no contact.
    func testParticipantsSheet_resolvingAgain_replacesTheRowsReachedAndKeepsTheRest() {
        let shown = [senderRow("ada"), senderRow("bob"), senderRow("cy"), senderRow("dee")]
        let bobAsContact = senderRow("bob", id: "contact:bob-card", name: "Bob Contact")

        XCTAssertEqual(
            sendersToDraw(resolvedSoFar: [senderRow("ada"), bobAsContact], shown: shown),
            [senderRow("ada"), bobAsContact, senderRow("cy"), senderRow("dee")]
        )
    }

    /// A shown row is reached where its address is not after the last resolved sender's,
    /// and is then drawn only as the resolve lists it. Ada is a contact now, so her row has
    /// another `id`, and her old row is not kept beside it. Cy is not yet reached.
    ///
    /// Revert-check: leaving out a shown row only where a resolved sender has its `id` (no
    /// `normalizedAddress(row) > lastResolvedAddress` in
    /// `ParticipantsListPolicy.sendersToDraw`) makes this fail: Ada's old row is drawn a
    /// second time, after her new one.
    func testParticipantsSheet_resolvingAgain_leavesOutAReachedRowTheResolveNoLongerLists() {
        let shown = [senderRow("ada"), senderRow("cy")]
        let adaAsContact = senderRow("ada", id: "contact:ada-card", name: "Ada Contact")

        XCTAssertEqual(
            sendersToDraw(resolvedSoFar: [adaAsContact], shown: shown),
            [adaAsContact, senderRow("cy")]
        )
    }

    /// A contact that has gained an earlier address is listed under that one now, and its
    /// row under the later address is not drawn too: two rows of one `id` in a `ForEach`
    /// are drawn as one or as neither.
    ///
    /// Revert-check: the `!resolvedIDs.contains(id(row))` of
    /// `ParticipantsListPolicy.sendersToDraw` makes this fail: Cy's card is listed twice.
    func testParticipantsSheet_resolvingAgain_neverDrawsTwoRowsOfOneContact() {
        let cyUnderLaterAddress = senderRow("cy", id: "contact:cy-card", name: "Cy Contact")
        let cyUnderEarlierAddress = senderRow("ada", id: "contact:cy-card", name: "Cy Contact")
        let shown = [senderRow("ada"), cyUnderLaterAddress, senderRow("dee")]

        let drawn = sendersToDraw(resolvedSoFar: [cyUnderEarlierAddress], shown: shown)

        XCTAssertEqual(drawn, [cyUnderEarlierAddress, senderRow("dee")])
        XCTAssertEqual(Set(drawn.map(\.id)).count, drawn.count)
    }

    /// Nothing resolved yet is no reason to empty the sheet.
    ///
    /// Revert-check: the `guard let lastResolved = resolvedSoFar.last else { return shown }`
    /// of `ParticipantsListPolicy.sendersToDraw` (return `resolvedSoFar` there) makes this
    /// fail.
    func testParticipantsSheet_nothingResolvedSoFar_keepsTheRowsShown() {
        let shown = [senderRow("ada"), senderRow("bob")]

        XCTAssertEqual(sendersToDraw(resolvedSoFar: [], shown: shown), shown)
    }

    private struct SenderRow: Equatable {
        let id: String
        let address: String
        let name: String
    }

    /// A row for `<localPart>@example.com`, which is no contact unless `id` says so.
    private func senderRow(_ localPart: String, id: String? = nil, name: String? = nil) -> SenderRow {
        let address = "\(localPart)@example.com"
        return SenderRow(id: id ?? "email:\(address)", address: address, name: name ?? localPart)
    }

    private func sendersToDraw(resolvedSoFar: [SenderRow], shown: [SenderRow]) -> [SenderRow] {
        ParticipantsListPolicy.sendersToDraw(
            resolvedSoFar: resolvedSoFar,
            shown: shown,
            id: { $0.id },
            normalizedAddress: { $0.address }
        )
    }

    func testChatNavigation_duringReplySend_staysAvailable() {
        // The back chevron, swipe-back and menu used to hide or disable for
        // every send, so the navigation bar blinked on each reply.
        // Revert-check: making ChatView.allowsNavigationExit return
        // !isSending makes this test fail.
        // HONEST SCOPE: XCTest cannot inspect the navigation modifier; this
        // pins the policy the back button and the action menu share.
        XCTAssertTrue(ChatView.allowsNavigationExit(isSending: true))
        XCTAssertTrue(ChatView.allowsNavigationExit(isSending: false))
    }

    func testConversationMutatingActions_whileReplySendOwnsComposer_wait() {
        // Revert-check: removing the isSending gate from
        // ChatView.allowsConversationExit makes this test fail.
        // HONEST SCOPE: this pins the policy behind the drained auto-dismiss,
        // not its call site. Archive and Report Spam defer through
        // ChatConversationExitActionPolicy (ChatConversationExitActionPolicyTests,
        // and the ChatViewModelTests `testConversationExitAction_` cases).
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
#endif
