import SwiftUI
import CoreData

struct ConversationListView: View {
    @FetchRequest private var conversations: FetchedResults<Conversation>

    init() {
        let request = NSFetchRequest<Conversation>(entityName: "Conversation")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Conversation.pinned, ascending: false),
            NSSortDescriptor(keyPath: \Conversation.lastMessageDate, ascending: false)
        ]
        request.predicate = NSPredicate(format: "hidden == NO")
        request.fetchBatchSize = 20  // Load conversations in batches for better memory usage
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]  // Prefetch to avoid N+1
        _conversations = FetchRequest(fetchRequest: request)
    }
    
    @StateObject private var syncEngine = SyncEngine.shared
    @State private var selectedConversation: Conversation?
    @State private var searchText = ""
    @State private var showingComposer = false
    @State private var showingSettings = false
    @State private var syncTimer: Timer?
    @State private var hasPerformedInitialSync = false
    
    var body: some View {
        ZStack {
            List {
                    ForEach(filteredConversations) { conversation in
                        ZStack {
                            NavigationLink(destination: ChatView(conversation: conversation)) {
                                EmptyView()
                            }
                            .opacity(0)

                            ConversationRowView(conversation: conversation)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.visible)
                    }
                    .onDelete(perform: deleteConversations)
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("Chats")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: { showingSettings = true }) {
                            Image(systemName: "gear")
                        }
                    }
                }
                .refreshable {
                    await performSync()
                }
                .sheet(isPresented: $showingComposer) {
                    NewMessageView()
                }
                .sheet(isPresented: $showingSettings) {
                    NavigationStack {
                        SettingsView()
                    }
                }
                .onAppear {
                    performInitialSync()
                    startPeriodicSync()
                    prefetchPersonData()
                }
                .onDisappear {
                    stopPeriodicSync()
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 68)
                }
                .onTapGesture {
                    hideKeyboard()
                }

            // Floating search bar with compose button
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    // Search bar
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 16))

                        TextField("Search", text: $searchText)
                            .textFieldStyle(.plain)

                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 16))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)

                    // Compose button with clear liquid glass design
                    Button(action: { showingComposer = true }) {
                        ZStack {
                            // Clear liquid glass background
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            LinearGradient(
                                                gradient: Gradient(colors: [
                                                    Color.white.opacity(0.6),
                                                    Color.white.opacity(0.2)
                                                ]),
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 1.5
                                        )
                                )
                                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)

                            // Pencil icon
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.primary)
                        }
                        .frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }
    
    private func performInitialSync() {
        guard !hasPerformedInitialSync else { return }

        // Only mark as performed if we're actually authenticated
        guard AuthSession.shared.isAuthenticated else {
            print("Skipping initial sync - not authenticated")
            return
        }

        hasPerformedInitialSync = true

        Task {
            do {
                // Try incremental sync first, it will fall back to initial sync if needed
                try await syncEngine.performIncrementalSync()
            } catch {
                print("Initial sync error: \(error)")
            }
        }
    }
    
    private var filteredConversations: [Conversation] {
        if searchText.isEmpty {
            return Array(conversations)
        } else {
            return conversations.filter { conversation in
                conversation.displayName?.localizedCaseInsensitiveContains(searchText) ?? false ||
                conversation.snippet?.localizedCaseInsensitiveContains(searchText) ?? false
            }
        }
    }
    
    private func refresh() {
        Task {
            await performSync()
        }
    }
    
    private func performSync() async {
        do {
            try await syncEngine.performIncrementalSync()
        } catch {
            print("Sync error: \(error)")
        }
    }
    
    private func deleteConversations(at offsets: IndexSet) {
        Task {
            for index in offsets {
                let conversation = filteredConversations[index]

                // Archive in Gmail first
                await archiveConversationInGmail(conversation)

                // Then hide locally
                conversation.hidden = true
            }
            do {
                try CoreDataStack.shared.save(context: CoreDataStack.shared.viewContext)
            } catch {
                print("Failed to delete conversation: \(error)")
                // Show error to user
            }
        }
    }

    private func archiveConversationInGmail(_ conversation: Conversation) async {
        // Get all message IDs from the conversation
        guard let messages = conversation.value(forKey: "messages") as? Set<Message> else { return }
        let messageIds = messages.compactMap { $0.value(forKey: "id") as? String }

        guard !messageIds.isEmpty else { return }

        do {
            try await GmailAPIClient.shared.archiveMessages(ids: messageIds)
            print("Archived \(messageIds.count) messages in Gmail")
        } catch {
            print("Failed to archive messages in Gmail: \(error)")
            // Continue with local deletion even if Gmail archive fails
        }
    }
    
    private func startPeriodicSync() {
        // Stop any existing timer
        stopPeriodicSync()

        // Start a new timer that fires every 60 seconds (increased from 30)
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak syncEngine] _ in
            Task { @MainActor [weak syncEngine] in
                guard let syncEngine = syncEngine else { return }
                // Only sync if not already syncing
                if !syncEngine.isSyncing {
                    print("Performing periodic sync at \(Date())")
                    do {
                        try await syncEngine.performIncrementalSync()
                    } catch {
                        print("Periodic sync error: \(error)")
                    }
                }
            }
        }
    }
    
    private func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func prefetchPersonData() {
        Task {
            // Prefetch Person data for visible conversations to avoid N+1 queries
            let allEmails = conversations.prefix(30).flatMap { conversation -> [String] in
                guard let participants = conversation.participants else {
                    return []
                }
                return participants.compactMap { $0.person?.email }
            }
            await PersonCache.shared.prefetch(emails: Array(Set(allEmails)))
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}