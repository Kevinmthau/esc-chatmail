import SwiftUI
import CoreData

struct ConversationListView: View {
    @ObservedObject private var authSession: AuthSession
    @StateObject private var viewModel: ConversationListViewModel
    private let deps: Dependencies
    private let viewContext: NSManagedObjectContext
    /// Built once at init instead of inside `navigationDestination`: the bundle
    /// holds only stable service references, stateless service instances, and
    /// factory closures — nothing per-conversation — so rebuilding it on every
    /// destination body evaluation only churned fresh service instances.
    /// `ContentView` recreates this view across sign-out/sign-in, so the bundle
    /// never outlives the account it was built for.
    private let chatDependencies: ChatDependencies

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
    }

    var body: some View {
        conversationList
            .conversationListBottomBar(bottomBar)
            .environment(\.managedObjectContext, viewContext)
            .environmentObject(deps)
            .environmentObject(authSession)
    }

    // MARK: - Conversation List

    @State private var selectedConversation: Conversation?
    @State private var pendingConversationReference: ConversationReference?
    @State private var showingComposer = false
    @FocusState private var isSearchFieldFocused: Bool

    private var conversationList: some View {
        List {
            ForEach(Array(viewModel.filteredConversationItems.enumerated()), id: \.element.id) { index, item in
                // One structural path for both selection modes: an if/else here
                // would make the arms `_ConditionalContent`, so toggling Select
                // tore down and rebuilt every visible row subtree (row @State
                // reset, `.task(id:)` re-fired, avatar loaders recreated) —
                // the same identity swap PR #182 removed inside the row view.
                // Mode differences live inside stable modifiers instead: the
                // checkbox is a conditional sibling, the tap gesture routes by
                // mode, and the swipe-action content empties while selecting
                // (empty content yields no swipe actions).
                HStack(spacing: 0) {
                    if viewModel.isSelecting {
                        selectionButton(for: item.id)
                    }
                    conversationRow(for: item)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if viewModel.isSelecting {
                                viewModel.toggleSelection(for: item.id)
                            } else {
                                isSearchFieldFocused = false
                                selectedConversation = resolveConversation(with: item.id)
                            }
                        }
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if !viewModel.isSelecting {
                        Button(role: .destructive) {
                            viewModel.archiveConversation(withID: item.id)
                        } label: {
                            SwiftUI.Label("Archive", systemImage: "archivebox")
                        }
                        .tint(.blue)
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if !viewModel.isSelecting {
                        Button {
                            viewModel.toggleConversationReadState(withID: item.id)
                        } label: {
                            if item.snapshot.inboxUnreadCount > 0 {
                                SwiftUI.Label("Read", systemImage: "envelope.open")
                            } else {
                                SwiftUI.Label("Unread", systemImage: "envelope.badge")
                            }
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .listStyle(.plain)
        .animation(nil, value: viewModel.filteredConversationItems.count)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(
            ConversationListChromePolicy.navigationTitle(
                isSelecting: viewModel.isSelecting,
                selectedCount: viewModel.selectedConversationIDs.count
            )
        )
        .navigationDestination(item: $selectedConversation) { conversation in
            ChatView(
                conversation: conversation,
                chatDependencies: chatDependencies,
                makeForwardComposeView: { context in
                    ComposeView(mode: .forward(context), deps: deps)
                }
            )
            .id(conversation.objectID)
        }
        .toolbar { toolbarContent }
        .refreshable { await viewModel.performSync() }
        .sheet(isPresented: $showingComposer, onDismiss: handleComposerDismiss) {
            ComposeView(
                mode: .newMessage,
                presentationStyle: .iMessage,
                deps: deps,
                onSendConversation: { conversationReference in
                    openConversationIfAvailable(conversationReference: conversationReference)
                }
            )
        }
        .onAppear {
            AppPrewarmer.prewarmAll()  // Safe to call repeatedly; each prewarm runs only once per launch.
            viewModel.onAppear(in: viewContext)
            // Lookups never prompt on their own, so this is the one deliberate
            // Contacts permission request (no-op after first launch/answer).
            ContactsAuthorizationCoordinator.shared.requestAccessOnFirstAuthenticatedLaunchIfNeeded()
        }
        .onDisappear {
            isSearchFieldFocused = false
            viewModel.onDisappear(preservePreviewRepair: authSession.canAccessMailbox)
        }
    }

    private func conversationRow(for item: ConversationListItem) -> some View {
        ConversationRowView(
            snapshot: item.snapshot,
            conversationObjectID: item.id,
            conversationContext: viewContext,
            currentUserEmail: authSession.userEmail ?? "",
            participantLoader: deps.participantLoader
        )
        .onAppear {
            viewModel.loadMoreIfNeeded(currentItem: item)
        }
    }

    private func selectionButton(for objectID: NSManagedObjectID) -> some View {
        Button {
            viewModel.toggleSelection(for: objectID)
        } label: {
            Image(systemName: viewModel.selectedConversationIDs.contains(objectID) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundColor(viewModel.selectedConversationIDs.contains(objectID) ? .blue : .gray)
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.trailing, 8)
    }

    // MARK: - Toolbar

    /// Select (Cancel while selecting) leads and the filter menu (Select All
    /// while selecting) trails, as in Messages. They stay plain toolbar items so
    /// the system styles them — glass capsule and circle on iOS 26.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(ConversationListChromePolicy.leadingButtonTitle(isSelecting: viewModel.isSelecting)) {
                isSearchFieldFocused = false
                withAnimation {
                    viewModel.toggleSelectionMode()
                }
            }
        }
        switch trailingToolbarItem {
        case .filterMenu:
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
        case let .selectAll(title, isEnabled):
            ToolbarItem(placement: .topBarTrailing) {
                Button(title) {
                    viewModel.selectAllVisibleConversations()
                }
                .disabled(!isEnabled)
            }
        }
    }

    private var trailingToolbarItem: ConversationListChromePolicy.TrailingItem {
        ConversationListChromePolicy.trailingItem(
            isSelecting: viewModel.isSelecting,
            selectedCount: viewModel.selectedConversationIDs.count,
            visibleCount: viewModel.filteredConversationItems.count
        )
    }

    private var filterMenu: some View {
        Menu {
            ForEach(ConversationFilter.allCases, id: \.self) { filter in
                Button {
                    // Each choice resigns search focus itself: the menu now
                    // sits in the navigation bar, where SwiftUI hosts it as a
                    // native bar-button menu and a gesture on its label (the
                    // old `simultaneousGesture` resign) is not reliably
                    // delivered, and Menu has no pre-presentation hook.
                    isSearchFieldFocused = false
                    viewModel.currentFilter = filter
                } label: {
                    SwiftUI.Label(filter.rawValue, systemImage: filter.icon)
                }
            }
        } label: {
            SwiftUI.Label("Filter", systemImage: viewModel.currentFilter.icon)
        }
        .accessibilityLabel("Filter conversations")
    }

    // MARK: - Bottom Bar

    /// Search field and compose button share one height, as in Messages.
    private static let bottomBarControlHeight: CGFloat = 48
    private static let bottomBarHorizontalPadding: CGFloat = 20
    private static let bottomBarBottomPadding: CGFloat = 8

    private var bottomBar: some View {
        Group {
            switch ConversationListChromePolicy.bottomBar(
                isSelecting: viewModel.isSelecting,
                selectedCount: viewModel.selectedConversationIDs.count
            ) {
            case .selectionActions:
                selectionActionBar
            case .searchAndCompose:
                searchAndComposeBar
            }
        }
    }

    private var selectionActionBar: some View {
        HStack(spacing: 20) {
            actionCapsuleButton(title: "Archive", systemImage: "archivebox") {
                viewModel.archiveSelectedConversations()
            }
            actionCapsuleButton(title: "Spam", systemImage: "exclamationmark.triangle") {
                viewModel.reportSpamSelectedConversations()
            }
        }
        .conversationListGlassGroup()
        .padding(.horizontal, Self.bottomBarHorizontalPadding)
        .padding(.bottom, Self.bottomBarBottomPadding)
    }

    /// Capsule-shaped action-bar button; the archive and spam buttons were
    /// byte-for-byte twins apart from icon, title, and action.
    private func actionCapsuleButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                Text(title)
                    .font(.system(size: 17, weight: .medium))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .conversationListGlassBackground(Capsule(), legacyMaterial: .thinMaterial)
        }
    }

    /// Messages' bottom bar: the search field takes all the width the compose
    /// button leaves.
    private var searchAndComposeBar: some View {
        HStack(spacing: 12) {
            searchBar
            composeButton
        }
        .conversationListGlassGroup()
        .padding(.horizontal, Self.bottomBarHorizontalPadding)
        .padding(.bottom, Self.bottomBarBottomPadding)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 18, weight: .medium))

            TextField("Search", text: $viewModel.searchText, prompt: Text("Search").foregroundColor(.secondary))
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .regular))
                .focused($isSearchFieldFocused)

            if !viewModel.searchText.isEmpty {
                Button(action: { viewModel.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 18, weight: .medium))
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: Self.bottomBarControlHeight)
        .conversationListGlassBackground(Capsule(), isInteractive: false)
    }

    private var composeButton: some View {
        Button(action: {
            isSearchFieldFocused = false
            showingComposer = true
        }) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: Self.bottomBarControlHeight, height: Self.bottomBarControlHeight)
                .contentShape(Circle())
                .conversationListGlassBackground(Circle())
        }
        .accessibilityLabel("Compose new message")
        .accessibilityIdentifier("ComposeNewMessageButton")
    }

    @MainActor
    private func handleComposerDismiss() {
        guard let conversationReference = pendingConversationReference else { return }
        openConversationIfAvailable(conversationReference: conversationReference)
    }

    /// Attempts immediate navigation to a conversation by persistent conversation reference.
    /// If the conversation is not resolvable yet, defers navigation until next sheet dismissal.
    @MainActor
    private func openConversationIfAvailable(conversationReference: ConversationReference) {
        isSearchFieldFocused = false
        guard let objectID = conversationReference.resolveObjectID(in: viewContext) else {
            pendingConversationReference = conversationReference
            return
        }

        if let conversation = try? viewContext.existingObject(with: objectID) as? Conversation,
           conversation.archivedAt == nil {
            selectedConversation = conversation
            pendingConversationReference = nil
            return
        }

        pendingConversationReference = conversationReference
    }

    private func resolveConversation(with objectID: NSManagedObjectID) -> Conversation? {
        try? viewContext.existingObject(with: objectID) as? Conversation
    }
}
