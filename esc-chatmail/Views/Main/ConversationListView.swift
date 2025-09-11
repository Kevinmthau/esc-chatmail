import SwiftUI
import CoreData

struct ConversationListView: View {
    @FetchRequest(
        entity: Conversation.entity(),
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Conversation.pinned, ascending: false),
            NSSortDescriptor(keyPath: \Conversation.lastMessageDate, ascending: false)
        ],
        predicate: NSPredicate(format: "hidden == NO")
    ) private var conversations: FetchedResults<Conversation>
    
    @StateObject private var syncEngine = SyncEngine.shared
    @State private var selectedConversation: Conversation?
    @State private var searchText = ""
    @State private var showingComposer = false
    @State private var showingSettings = false
    
    var body: some View {
        List {
                if syncEngine.isSyncing {
                    HStack {
                        ProgressView()
                        Text(syncEngine.syncStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
                
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
            }
    }
    
    private func performInitialSync() {
        Task {
            do {
                try await syncEngine.performInitialSync()
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
        for index in offsets {
            let conversation = filteredConversations[index]
            conversation.hidden = true
        }
        CoreDataStack.shared.save(context: CoreDataStack.shared.viewContext)
    }
}