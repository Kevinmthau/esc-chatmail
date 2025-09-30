import SwiftUI
import CoreData
import Combine
import UIKit

// MARK: - Conversation List State
@MainActor
final class ConversationListState: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var isLoading = false
    @Published var selectedConversation: Conversation?
    @Published var preloadedIds = Set<String>()

    private let cache = ConversationCache.shared
    private let coreDataStack = CoreDataStack.shared
    private var cancellables = Set<AnyCancellable>()
    private var preloadTask: Task<Void, Never>?

    init() {
        setupObservers()
    }

    private func setupObservers() {
        // Listen for sync completion
        NotificationCenter.default.publisher(for: .syncCompleted)
            .sink { [weak self] _ in
                Task {
                    await self?.refreshConversations()
                }
            }
            .store(in: &cancellables)
    }

    func refreshConversations() async {
        isLoading = true

        let context = coreDataStack.viewContext
        let request = Conversation.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Conversation.pinned, ascending: false),
            NSSortDescriptor(keyPath: \Conversation.lastMessageDate, ascending: false)
        ]
        request.predicate = NSPredicate(format: "hidden == NO")
        request.fetchBatchSize = 30
        request.relationshipKeyPathsForPrefetching = ["messages", "participants", "participants.person"]

        do {
            let fetchedConversations = try context.fetch(request)
            conversations = fetchedConversations

            // Warm cache with recent conversations
            cache.warmCache(with: Array(fetchedConversations.prefix(10)))

            // Prefetch Person data for all participants to avoid N+1 queries
            let allEmails = fetchedConversations.prefix(30).flatMap { conversation -> [String] in
                guard let participants = conversation.participants else {
                    return []
                }
                return participants.compactMap { $0.person?.email }
            }
            await PersonCache.shared.prefetch(emails: Array(Set(allEmails)))

            isLoading = false
        } catch {
            print("Failed to fetch conversations: \(error)")
            isLoading = false
        }
    }

    func preloadAdjacentConversations(for conversation: Conversation) {
        guard let index = conversations.firstIndex(of: conversation) else { return }

        var toPreload: [String] = []

        // Preload next 3 conversations
        for i in 1...3 {
            let nextIndex = index + i
            if nextIndex < conversations.count {
                let conversationId = conversations[nextIndex].id.uuidString
                if !preloadedIds.contains(conversationId) {
                    toPreload.append(conversationId)
                    preloadedIds.insert(conversationId)
                }
            }
        }

        // Preload previous 2 conversations
        for i in 1...2 {
            let prevIndex = index - i
            if prevIndex >= 0 {
                let conversationId = conversations[prevIndex].id.uuidString
                if !preloadedIds.contains(conversationId) {
                    toPreload.append(conversationId)
                    preloadedIds.insert(conversationId)
                }
            }
        }

        if !toPreload.isEmpty {
            cache.preload(toPreload)
        }
    }

    func selectConversation(_ conversation: Conversation) {
        selectedConversation = conversation
        preloadAdjacentConversations(for: conversation)
    }
}

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
            print("Sync failed: \(error)")
        }
    }
}

// MARK: - Optimized Conversation Row
struct OptimizedConversationRow: View {
    @ObservedObject var conversation: Conversation
    let onAppear: () -> Void

    private var participantNames: String {
        guard let participantsSet = conversation.participants as? NSSet else {
            return "Unknown"
        }

        let names = participantsSet
            .compactMap { ($0 as? ConversationParticipant)?.person?.displayName ?? ($0 as? ConversationParticipant)?.person?.email }
            .prefix(3)
            .joined(separator: ", ")

        return names.isEmpty ? "No participants" : names
    }

    private var timeString: String {
        guard let date = conversation.lastMessageDate else { return "" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            AvatarView(name: participantNames)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                // Header
                HStack {
                    Text(conversation.displayName ?? participantNames)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    Text(timeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Snippet
                Text(conversation.snippet ?? "")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                // Indicators
                HStack(spacing: 8) {
                    if conversation.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    if conversation.inboxUnreadCount > 0 {
                        UnreadBadge(count: Int(conversation.inboxUnreadCount))
                    }

                    if conversation.hasInbox {
                        Image(systemName: "tray.fill")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 20)
        .background(Color(.systemBackground))
        .onAppear {
            onAppear()
        }
    }
}

// MARK: - Avatar View
struct AvatarView: View {
    let name: String

    private var initials: String {
        let components = name.components(separatedBy: " ")
        let initials = components.prefix(2).compactMap { $0.first }.map { String($0) }.joined()
        return initials.isEmpty ? "?" : initials
    }

    private var backgroundColor: Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .red]
        let index = abs(name.hashValue) % colors.count
        return colors[index]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor.gradient)

            Text(initials.uppercased())
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Unread Badge
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.blue)
            .clipShape(Capsule())
    }
}

// MARK: - Conversation List Skeleton View
struct ConversationListSkeletonView: View {
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<10) { _ in
                    ConversationRowSkeleton()
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(height: 1)
                }
            }
        }
    }
}

struct ConversationRowSkeleton: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 150, height: 16)

                    Spacer()

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 40, height: 12)
                }

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 14)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 200, height: 14)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .opacity(isAnimating ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 1.0).repeatForever(), value: isAnimating)
        .onAppear {
            isAnimating = true
        }
    }
}