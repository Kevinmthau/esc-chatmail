import SwiftUI
import CoreData

struct ConversationListView: View {
    @FetchRequest private var conversations: FetchedResults<Conversation>
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var deps: Dependencies
    @StateObject private var viewModel: ConversationListViewModel

    @MainActor
    init(deps: Dependencies? = nil) {
        let resolvedDeps = deps ?? Dependencies.shared
        _viewModel = StateObject(wrappedValue: ConversationListViewModel(deps: resolvedDeps))
        let request = NSFetchRequest<Conversation>(entityName: "Conversation")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Conversation.pinned, ascending: false),
            NSSortDescriptor(keyPath: \Conversation.lastMessageDate, ascending: false)
        ]
        // Show only active (non-archived) conversations
        // archivedAt == nil means the conversation is active
        request.predicate = NSPredicate(format: "archivedAt == nil")
        request.fetchBatchSize = 20
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]
        _conversations = FetchRequest(fetchRequest: request)
    }

    var body: some View {
        conversationList
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
    }

    // MARK: - Conversation List

    @State private var selectedConversation: Conversation?
    @State private var pendingConversationReference: ConversationReference?

    private var conversationList: some View {
        List {
            ForEach(Array(viewModel.filteredConversationItems.enumerated()), id: \.element.id) { index, item in
                if viewModel.isSelecting {
                    HStack(spacing: 0) {
                        selectionButton(for: item.id)
                        conversationRow(for: item)
                            .contentShape(Rectangle())
                            .onTapGesture { viewModel.toggleSelection(for: item.id) }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                } else {
                    conversationRow(for: item)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedConversation = resolveConversation(with: item.id)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                viewModel.archiveConversation(withID: item.id)
                            } label: {
                                SwiftUI.Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
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
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(viewModel.isSelecting ? "\(viewModel.selectedConversationIDs.count) Selected" : "Chats")
        .navigationDestination(item: $selectedConversation) { conversation in
            let chatDependencies = deps.makeChatDependencies()
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
        .sheet(isPresented: $viewModel.showingComposer, onDismiss: handleComposerDismiss) {
            ComposeView(
                mode: .newMessage,
                presentationStyle: .iMessage,
                deps: deps,
                onSendConversation: { conversationReference in
                    openConversationIfAvailable(conversationReference: conversationReference)
                }
            )
        }
        .sheet(isPresented: $viewModel.showingSettings) {
            NavigationStack { SettingsView() }
        }
        .onAppear {
            AppPrewarmer.prewarmAll()  // Safe to call repeatedly; each prewarm runs only once per launch.
            viewModel.onAppear(conversations: Array(conversations), in: viewContext)
        }
        .onDisappear {
            viewModel.onDisappear()
        }
    }

    private func conversationRow(for item: ConversationListItem) -> some View {
        ConversationRowView(
            snapshot: item.snapshot,
            conversationObjectID: item.id,
            conversationContext: viewContext,
            currentUserEmail: deps.authSession.userEmail ?? "",
            participantLoader: deps.participantLoader
        )
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
                Button(action: { viewModel.showingSettings = true }) {
                    Image(systemName: "gear")
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(viewModel.isSelecting ? "Cancel" : "Select") {
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
            archiveButton
            spamButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var archiveButton: some View {
        Button(action: { viewModel.archiveSelectedConversations() }) {
            HStack(spacing: 10) {
                Image(systemName: "archivebox")
                    .font(.system(size: 20, weight: .medium))
                Text("Archive")
                    .font(.system(size: 17, weight: .medium))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(glassBackground)
        }
    }

    private var spamButton: some View {
        Button(action: { viewModel.reportSpamSelectedConversations() }) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20, weight: .medium))
                Text("Spam")
                    .font(.system(size: 17, weight: .medium))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(glassBackground)
        }
    }

    private var glassBackground: some View {
        ZStack {
            Color(UIColor.systemBackground).opacity(0.95)
            Capsule()
                .fill(.thinMaterial)
        }
        .clipShape(Capsule())
        .overlay(
            Capsule()
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
        .background(
            Capsule()
                .fill(Color(UIColor.systemBackground).opacity(0.95))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.gray.opacity(0.3), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
        )
    }

    private var composeButton: some View {
        Button(action: { viewModel.showingComposer = true }) {
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
        guard let objectID = conversationReference.resolveObjectID(in: viewContext) else {
            pendingConversationReference = conversationReference
            return
        }

        if let conversation = conversations.first(where: { $0.objectID == objectID }) {
            selectedConversation = conversation
            pendingConversationReference = nil
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
            Circle()
                .fill(Color(UIColor.systemBackground).opacity(0.95))
                .overlay(
                    Circle()
                        .strokeBorder(Color.gray.opacity(0.3), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)

            Image(systemName: icon)
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.primary)
        }
        .frame(width: 52, height: 52)
    }
}
