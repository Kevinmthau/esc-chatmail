import SwiftUI
import CoreData
import Combine
import UIKit

// MARK: - Enhanced Conversation List View
struct EnhancedConversationListView: View {
    @StateObject private var listState = ConversationListState()
    @StateObject private var syncEngine = SyncEngine.shared
    @StateObject private var cache = ConversationCache.shared
    @State private var showingSettings = false
    @State private var searchText = ""

    var filteredConversations: [Conversation] {
        if searchText.isEmpty {
            return listState.conversations
        }
        return listState.conversations.filter { conversation in
            conversation.displayName?.localizedCaseInsensitiveContains(searchText) ?? false ||
            conversation.snippet?.localizedCaseInsensitiveContains(searchText) ?? false
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                if listState.isLoading && listState.conversations.isEmpty {
                    ConversationListSkeletonView()
                } else {
                    conversationList
                }

                if syncEngine.isSyncing {
                    syncProgressOverlay
                }
            }
            .navigationTitle("Inbox Chat")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(syncEngine.isSyncing ? 360 : 0))
                            .animation(
                                syncEngine.isSyncing ?
                                    .linear(duration: 1).repeatForever(autoreverses: false) :
                                    .default,
                                value: syncEngine.isSyncing
                            )
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                Text("Settings View")
            }
            .searchable(text: $searchText, prompt: "Search conversations")
            .refreshable {
                await performSync()
            }
            .task {
                await listState.refreshConversations()
            }
        }
    }

    private var conversationList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredConversations) { conversation in
                    NavigationLink(destination: VirtualScrollChatView(conversation: conversation)) {
                        OptimizedConversationRow(
                            conversation: conversation,
                            onAppear: {
                                handleConversationAppear(conversation)
                            }
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(
                        listState.selectedConversation == conversation ?
                        Color.accentColor.opacity(0.1) : Color.clear
                    )
                    .onTapGesture {
                        listState.selectConversation(conversation)
                    }

                    Rectangle()
                        .fill(Color(.separator))
                        .frame(height: 1)
                }
            }
        }
    }

    private var syncProgressOverlay: some View {
        VStack {
            HStack {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)

                Text(syncEngine.syncStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .cornerRadius(8)
            .padding()

            Spacer()
        }
    }

    private func handleConversationAppear(_ conversation: Conversation) {
        // Preload when conversation becomes visible
        let conversationId = conversation.id.uuidString
        if !listState.preloadedIds.contains(conversationId) {
            listState.preloadedIds.insert(conversationId)

            // Preload adjacent conversations
            Task {
                listState.preloadAdjacentConversations(for: conversation)
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
            await listState.refreshConversations()
        } catch {
            Log.error("Sync failed", category: .sync, error: error)
        }
    }
}
