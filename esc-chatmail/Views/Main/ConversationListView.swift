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
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
            .environment(\.managedObjectContext, viewContext)
            .environmentObject(deps)
            .environmentObject(authSession)
    }

    // MARK: - Conversation List

    @State private var selectedConversation: Conversation?
    @State private var pendingConversationReference: ConversationReference?
    @State private var showingComposer = false
    @State private var showingSettings = false
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
        .navigationTitle(viewModel.isSelecting ? "\(viewModel.selectedConversationIDs.count) Selected" : "Chats")
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
        .sheet(isPresented: $showingSettings) {
            SettingsView()
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if viewModel.isSelecting {
                Button(viewModel.selectedConversationIDs.count == viewModel.filteredConversationItems.count ? "Deselect All" : "Select All") {
                    viewModel.selectAllVisibleConversations()
                }
            } else {
                Button(action: {
                    isSearchFieldFocused = false
                    showingSettings = true
                }) {
                    Image(systemName: "gear")
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(viewModel.isSelecting ? "Cancel" : "Select") {
                isSearchFieldFocused = false
                withAnimation {
                    viewModel.toggleSelectionMode()
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        Group {
            if viewModel.isSelecting && !viewModel.selectedConversationIDs.isEmpty {
                selectionActionBar
            } else {
                navigationBar
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
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
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
            .background(glassSurface(Capsule(), material: .thinMaterial))
        }
    }

    /// Shared "glass" chrome for the bottom-bar surfaces: a 0.95-opacity
    /// system-background fill, a 0.5pt gray hairline stroke, and a soft drop
    /// shadow. Only the selection action bar passes `material:` (layering
    /// `.thinMaterial` over the fill); the search bar and circle buttons are
    /// deliberately material-free, matching the pre-refactor styling.
    private func glassSurface<S: InsettableShape>(_ shape: S, material: Material? = nil) -> some View {
        ZStack {
            shape
                .fill(Color(UIColor.systemBackground).opacity(0.95))
            if let material {
                shape
                    .fill(material)
            }
        }
        .overlay(
            shape
                .strokeBorder(Color.gray.opacity(0.3), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
    }

    private var navigationBar: some View {
        HStack(spacing: 14) {
            filterMenuButton
            searchBar
            composeButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var filterMenuButton: some View {
        Menu {
            ForEach(ConversationFilter.allCases, id: \.self) { filter in
                Button {
                    viewModel.currentFilter = filter
                } label: {
                    SwiftUI.Label(filter.rawValue, systemImage: filter.icon)
                }
            }
        } label: {
            circleButton(icon: viewModel.currentFilter.icon)
        }
        // Menu has no pre-presentation action hook; resign focus alongside the
        // label tap so the keyboard isn't dismissed out-of-band by the menu.
        .simultaneousGesture(TapGesture().onEnded { isSearchFieldFocused = false })
        .accessibilityLabel("Filter conversations")
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
        .padding(.vertical, 14)
        .background(glassSurface(Capsule()))
    }

    private var composeButton: some View {
        Button(action: {
            isSearchFieldFocused = false
            showingComposer = true
        }) {
            circleButton(icon: "square.and.pencil")
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

    private func circleButton(icon: String) -> some View {
        ZStack {
            glassSurface(Circle())

            Image(systemName: icon)
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.primary)
        }
        .frame(width: 52, height: 52)
    }
}
