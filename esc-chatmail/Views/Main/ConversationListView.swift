import SwiftUI
import CoreData

struct ConversationListView: View {
    @FetchRequest private var conversations: FetchedResults<Conversation>
    @StateObject private var viewModel = ConversationListViewModel()

    init() {
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

    private var filteredConversations: [Conversation] {
        viewModel.filteredConversations(from: Array(conversations))
    }

    var body: some View {
        ZStack {
            conversationList
            bottomBar
        }
    }

    // MARK: - Conversation List

    @State private var selectedConversation: Conversation?

    private var conversationList: some View {
        List {
            ForEach(Array(filteredConversations.enumerated()), id: \.element.objectID) { index, conversation in
                if viewModel.isSelecting {
                    HStack(spacing: 0) {
                        selectionButton(for: conversation)
                        ConversationRowView(conversation: conversation)
                            .contentShape(Rectangle())
                            .onTapGesture { viewModel.toggleSelection(for: conversation) }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                } else {
                    ConversationRowView(conversation: conversation)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedConversation = conversation
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                viewModel.archiveConversation(conversation)
                            } label: {
                                SwiftUI.Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                viewModel.toggleConversationReadState(conversation)
                            } label: {
                                if conversation.inboxUnreadCount > 0 {
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
        .animation(nil, value: filteredConversations.map { $0.objectID })
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(viewModel.isSelecting ? "\(viewModel.selectedConversationIDs.count) Selected" : "Chats")
        .navigationDestination(item: $selectedConversation) { conversation in
            ChatView(conversation: conversation)
        }
        .toolbar { toolbarContent }
        .refreshable { await viewModel.performSync() }
        .sheet(isPresented: $viewModel.showingComposer) { ComposeView(mode: .newMessage) }
        .sheet(isPresented: $viewModel.showingSettings) {
            NavigationStack { SettingsView() }
        }
        .onAppear {
            AppPrewarmer.prewarmAll()
            viewModel.onAppear(conversations: Array(conversations))
        }
        .onDisappear {
            viewModel.onDisappear()
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 80)
        }
    }

    private func selectionButton(for conversation: Conversation) -> some View {
        Button {
            viewModel.toggleSelection(for: conversation)
        } label: {
            Image(systemName: viewModel.selectedConversationIDs.contains(conversation.objectID) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundColor(viewModel.selectedConversationIDs.contains(conversation.objectID) ? .blue : .gray)
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
                Button(viewModel.selectedConversationIDs.count == filteredConversations.count ? "Deselect All" : "Select All") {
                    viewModel.selectAll(from: filteredConversations)
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
        VStack {
            Spacer()
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
            }

            Button(action: { }) {
                Image(systemName: "mic")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)
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
