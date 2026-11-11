#if os(macOS)
import SwiftUI
import CoreData

/// The signed-in Mac window: the conversation list in a sidebar and the selected chat beside it,
/// as in Messages (`docs/mac-imessage-ui-plan.md`, PR 1). iOS keeps `ConversationListView` in a
/// `NavigationStack` (`MailboxRootView`).
///
/// The sidebar's selection is the state everything here follows. One selected row is the open
/// chat; a chat closes by leaving the selection, never by `dismiss`
/// (`MacSidebarSelectionPolicy`, `ChatView.exitChat`). Nothing is selected at launch: opening a
/// chat marks it read, so the user picks the first one.
///
/// This view owns the list's view model, so it is built once per sign-in and outlives every chat
/// opened beside it. `ContentView` rebuilds this view across sign-out and sign-in, as it does the
/// iOS list, so neither the view model nor the chat dependency bundle outlives its account.
struct MacMailboxView: View {
    @ObservedObject private var authSession: AuthSession
    @StateObject private var viewModel: ConversationListViewModel
    @StateObject private var abandonedActions: AbandonedPendingActionsModel
    private let deps: Dependencies
    private let viewContext: NSManagedObjectContext
    /// Built once at init, as in `ConversationListView`: it holds nothing per-conversation.
    private let chatDependencies: ChatDependencies

    @State private var selection: Set<NSManagedObjectID> = []
    @State private var showingComposer = false
    @State private var pendingConversationReference: ConversationReference?
    /// Which columns the split view shows. Both, except for the one update in which the split
    /// view reports its sidebar closed (`MacSidebarVisibilityPolicy`), which the user can no
    /// longer make it do (`MacSidebarCollapseGuardView`).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @MainActor
    init(deps: Dependencies? = nil) {
        let resolvedDeps = deps ?? Dependencies.shared
        self.deps = resolvedDeps
        self.viewContext = resolvedDeps.viewContext
        self.chatDependencies = resolvedDeps.makeChatDependencies()
        _authSession = ObservedObject(wrappedValue: resolvedDeps.authSession)
        _viewModel = StateObject(
            wrappedValue: ConversationListViewModel(
                dependencies: resolvedDeps.makeConversationListDependencies()
            )
        )
        _abandonedActions = StateObject(
            wrappedValue: AbandonedPendingActionsModel(manager: resolvedDeps.pendingActionsManager)
        )
    }

    var body: some View {
        let visibleConversationIDs = viewModel.filteredConversationItems.map(\.id)

        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacConversationSidebar(
                viewModel: viewModel,
                abandonedActions: abandonedActions,
                syncEngine: deps.syncEngine,
                selection: $selection,
                currentUserEmail: authSession.userEmail ?? "",
                participantLoader: deps.participantLoader,
                viewContext: viewContext,
                onArchive: { archive($0) },
                onReportSpam: { reportSpam($0) },
                onNewMessage: { showingComposer = true }
            )
            // Messages has no Hide Sidebar button, and with one column hidden there would be
            // no list to pick a chat from. Removing the button does not keep the sidebar open.
            // This does: the divider stops at the column's minimum width, where without it a
            // drag on toward the window's edge closed the sidebar
            // (`MacSidebarCollapseGuardView`).
            .macSplitViewColumnCannotCollapse()
            .toolbar(removing: .sidebarToggle)
            // The column's last modifier, on purpose. Applied before `toolbar(removing:)`, the
            // width was ignored: the sidebar came up 144 points wide with a 140-point minimum
            // (measured 2026-11-11 in a throwaway program on macOS 27.2, with these modifiers in
            // both orders). `MacMailboxViewSourceTests` pins the order.
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
        } detail: {
            MacMailboxDetail(
                selection: selection,
                viewContext: viewContext,
                chatDependencies: chatDependencies,
                makeForwardComposeView: { context in
                    ComposeView(mode: .forward(context), deps: deps)
                },
                onExitChat: { closeChat($0) },
                onArchive: { archive($0) },
                onReportSpam: { reportSpam($0) }
            )
            .equatable()
            .toolbar {
                // The chat column's leading edge, where Messages has its compose button.
                ToolbarItem(placement: .navigation) {
                    Button {
                        showingComposer = true
                    } label: {
                        SwiftUI.Label("New Message", systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("ComposeNewMessageButton")
                }
            }
            // The chat's own toolbar item shows the conversation's name; the window title
            // would show it a second time beside it.
            .toolbar(removing: .title)
        }
        .onChange(of: visibleConversationIDs) { _, visibleIDs in
            dropUnopenableSelection(visibleIDs: Set(visibleIDs))
        }
        // The fallback behind `macSplitViewColumnCannotCollapse()`: if the sidebar is closed all
        // the same, put it back. Not `.constant(.all)`: that binding was measured not to hold it
        // open.
        .onChange(of: columnVisibility) { _, reported in
            if let correction = MacSidebarVisibilityPolicy.correction(for: reported) {
                columnVisibility = correction
            }
        }
        .appSheet(isPresented: $showingComposer, mac: .sized(.compose), onDismiss: handleComposerDismiss) {
            ComposeView(
                mode: .newMessage,
                presentationStyle: .iMessage,
                deps: deps,
                onSendConversation: { conversationReference in
                    openConversationIfAvailable(conversationReference)
                }
            )
        }
        .conversationListLifecycle(
            viewModel: viewModel,
            abandonedActions: abandonedActions,
            viewContext: viewContext,
            authSession: authSession
        )
        .environment(\.managedObjectContext, viewContext)
        .environmentObject(deps)
        .environmentObject(authSession)
    }

    // MARK: - Selection

    private typealias SelectionPolicy = MacSidebarSelectionPolicy

    /// Archive from the list: the Delete key, a row's context menu or swipe, or the chat column's
    /// button while several rows are selected.
    private func archive(_ requested: Set<NSManagedObjectID>) {
        performListAction(on: requested) { viewModel.archiveConversations(withIDs: $0) }
    }

    private func reportSpam(_ requested: Set<NSManagedObjectID>) {
        performListAction(on: requested) { viewModel.reportSpamConversations(withIDs: $0) }
    }

    /// Moves the selection first, so the chat column leaves the rows being removed before their
    /// conversations change under it, then runs the action on the rows the list shows.
    private func performListAction(
        on requested: Set<NSManagedObjectID>,
        _ action: (Set<NSManagedObjectID>) -> Void
    ) {
        let orderedVisibleIDs = viewModel.filteredConversationItems.map(\.id)
        let targets = SelectionPolicy.actionTargets(requested: requested, visibleIDs: Set(orderedVisibleIDs))
        guard !targets.isEmpty else { return }
        selection = SelectionPolicy.selectionAfterListAction(
            selection: selection,
            actedOn: targets,
            orderedVisibleIDs: orderedVisibleIDs
        )
        action(targets)
    }

    /// The open chat closed itself: its own Archive or Report Spam, or its conversation drained.
    private func closeChat(_ conversationID: NSManagedObjectID) {
        selection = SelectionPolicy.selectionAfterChatExit(selection: selection, exited: conversationID)
    }

    private func dropUnopenableSelection(visibleIDs: Set<NSManagedObjectID>) {
        let retained = SelectionPolicy.selectionAfterListChange(
            selection: selection,
            visibleIDs: visibleIDs,
            isOpenable: isOpenable(_:)
        )
        // Assign only a real change: this runs on every list publish.
        if retained != selection {
            selection = retained
        }
    }

    /// Whether a conversation the list is not showing can still be the open chat: it exists and
    /// is not archived, so only a search or a filter is hiding its row. The same test a
    /// just-sent conversation passes before it is opened
    /// (`ConversationReference.openableConversation`).
    private func isOpenable(_ conversationID: NSManagedObjectID) -> Bool {
        guard let conversation = try? viewContext.existingObject(with: conversationID) as? Conversation,
              !conversation.isDeleted else {
            return false
        }
        return conversation.archivedAt == nil
    }

    // MARK: - New Message

    private func handleComposerDismiss() {
        guard let conversationReference = pendingConversationReference else { return }
        openConversationIfAvailable(conversationReference)
    }

    /// Selects the conversation a new message went to. If it is not resolvable yet, tries again
    /// when the compose sheet has dismissed, as the iOS list does before it pushes the chat.
    private func openConversationIfAvailable(_ conversationReference: ConversationReference) {
        guard let conversation = conversationReference.openableConversation(in: viewContext) else {
            pendingConversationReference = conversationReference
            return
        }
        selection = [conversation.objectID]
        pendingConversationReference = nil
    }
}
#endif
