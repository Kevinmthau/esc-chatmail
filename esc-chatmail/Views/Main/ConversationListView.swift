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
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingComposer = true }) {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .searchable(text: $searchText)
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
            }
            .onDisappear {
                stopPeriodicSync()
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
        // Note: SwiftUI Views are structs, so we don't need weak references
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            Task {
                // Only sync if not already syncing
                if await !self.syncEngine.isSyncing {
                    print("Performing periodic sync at \(Date())")
                    do {
                        try await self.syncEngine.performIncrementalSync()
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
}