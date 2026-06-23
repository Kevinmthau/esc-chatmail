import SwiftUI
import CoreData

struct InboxWindowProvider {
    static let initialLimit = VirtualScrollConfiguration.default.pageSize
    static let pageSize = VirtualScrollConfiguration.default.pageSize
    static let preloadThreshold = VirtualScrollConfiguration.default.preloadThreshold

    func fetchWindow(
        in context: NSManagedObjectContext,
        limit: Int,
        searchText: String
    ) -> [Message] {
        let request = NSFetchRequest<Message>(entityName: "Message")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Message.internalDate, ascending: false)]
        request.predicate = predicate(searchText: searchText)
        request.fetchLimit = limit
        request.fetchBatchSize = min(Self.pageSize, max(limit, 1))
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]
        request.includesPendingChanges = true

        do {
            return try context.fetch(request)
        } catch {
            Log.error("Failed to fetch inbox message window", category: .coreData, error: error)
            return []
        }
    }

    private func predicate(searchText: String) -> NSPredicate {
        let inboxPredicate = NSPredicate(
            format: "ANY labels.id == %@ AND NOT (ANY labels.id == %@)",
            "INBOX",
            "DRAFT"
        )
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchText.isEmpty else { return inboxPredicate }

        let searchPredicate = NSPredicate(
            format: "(subject CONTAINS[cd] %@) OR (snippet CONTAINS[cd] %@) OR (senderName CONTAINS[cd] %@)",
            trimmedSearchText,
            trimmedSearchText,
            trimmedSearchText
        )
        return NSCompoundPredicate(andPredicateWithSubpredicates: [inboxPredicate, searchPredicate])
    }
}

struct InboxListView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest private var messages: FetchedResults<Message>
    @StateObject private var messageActions: MessageActions
    private let deps: Dependencies
    private let fullEmailReaderCoordinator: FullEmailReaderCoordinator
    private let inboxWindowProvider = InboxWindowProvider()

    @MainActor
    init(
        deps: Dependencies? = nil,
        fullEmailReaderCoordinator: FullEmailReaderCoordinator? = nil
    ) {
        let resolvedDeps = deps ?? Dependencies.shared
        self.deps = resolvedDeps
        self.fullEmailReaderCoordinator = fullEmailReaderCoordinator ?? FullEmailReaderCoordinator()
        let request = NSFetchRequest<Message>(entityName: "Message")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Message.internalDate, ascending: false)]
        // Only show inbox messages that are not drafts
        request.predicate = NSPredicate(format: "ANY labels.id == %@ AND NOT (ANY labels.id == %@)", "INBOX", "DRAFT")
        request.fetchBatchSize = 25  // Load messages in batches for better performance
        _messages = FetchRequest(fetchRequest: request)
        _messageActions = StateObject(wrappedValue: resolvedDeps.makeMessageActions())
    }

    @State private var searchText = ""
    @State private var fullEmailOpenSession: FullEmailOpenSession?
    @State private var showingComposer = false
    @State private var cachedFilteredMessages: [Message] = []
    @State private var loadedMessageLimit = InboxWindowProvider.initialLimit
    @State private var hasLoadedAllMessages = false
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(cachedFilteredMessages) { message in
                    MessageRow(message: message)
                        .onAppear {
                            loadMoreIfNeeded(currentMessage: message)
                        }
                        .onTapGesture {
                            fullEmailOpenSession = fullEmailReaderCoordinator.openSession(for: message)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(action: { archiveMessage(message) }) {
                                SwiftUI.Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.purple)
                        }
                        .swipeActions(edge: .leading) {
                            Button(action: { toggleRead(message) }) {
                                SwiftUI.Label(message.isUnread ? "Read" : "Unread",
                                      systemImage: message.isUnread ? "envelope.open" : "envelope")
                            }
                            .tint(.blue)
                        }
                }
            }
            .navigationTitle("Inbox")
            .searchable(text: $searchText)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingComposer = true }) {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(item: $fullEmailOpenSession) { session in
                FullEmailReaderView(session: session)
            }
            .sheet(isPresented: $showingComposer) {
                ComposeView(mode: .newMessage, deps: deps)
            }
            .onAppear {
                updateFilteredMessages()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: viewContext)) { _ in
                updateFilteredMessages()
            }
            .onChange(of: searchText) { _, _ in
                loadedMessageLimit = InboxWindowProvider.initialLimit
                hasLoadedAllMessages = false
                updateFilteredMessages()
            }
        }
    }

    /// Updates the cached filtered messages when dependencies change.
    /// Caching prevents recalculation on every view body evaluation.
    private func updateFilteredMessages() {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let window: [Message]
        if trimmedSearchText.isEmpty {
            window = Array(messages.prefix(loadedMessageLimit))
        } else {
            window = inboxWindowProvider.fetchWindow(
                in: viewContext,
                limit: loadedMessageLimit,
                searchText: trimmedSearchText
            )
        }

        hasLoadedAllMessages = window.count < loadedMessageLimit
        cachedFilteredMessages = window
    }

    private func loadMoreIfNeeded(currentMessage message: Message) {
        guard !hasLoadedAllMessages else { return }
        guard let index = cachedFilteredMessages.firstIndex(where: { $0.objectID == message.objectID }) else { return }
        guard cachedFilteredMessages.distance(from: index, to: cachedFilteredMessages.endIndex) <= InboxWindowProvider.preloadThreshold else {
            return
        }

        loadedMessageLimit += InboxWindowProvider.pageSize
        updateFilteredMessages()
    }
    
    private func archiveMessage(_ message: Message) {
        Task {
            await messageActions.archive(message: message)
        }
    }

    private func toggleRead(_ message: Message) {
        Task {
            if message.isUnread {
                await messageActions.markAsRead(message: message)
            } else {
                await messageActions.markAsUnread(message: message)
            }
        }
    }
}

struct MessageRow: View {
    let message: Message
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if message.isUnread {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                }
                
                Text(getFromName())
                    .font(.headline)
                    .fontWeight(message.isUnread ? .bold : .regular)
                    .lineLimit(1)
                
                Spacer()
                
                Text(formatDate(message.internalDate))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if let subject = message.subject, !subject.isEmpty {
                Text(subject)
                    .font(.subheadline)
                    .fontWeight(message.isUnread ? .semibold : .regular)
                    .lineLimit(1)
            }
            
            Text(message.snippet ?? "")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
            
            if message.hasAttachments {
                HStack {
                    Image(systemName: "paperclip")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Attachment")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private func getFromName() -> String {
        guard let participants = message.participants else {
            return "Unknown"
        }
        
        let fromParticipant = participants.first { $0.participantKind == .from }
        guard let person = fromParticipant?.person else {
            return PersonDisplayNameResolver.fallbackSenderName()
        }

        return PersonDisplayNameResolver.senderDisplayName(
            email: person.email,
            contactDisplayName: nil,
            headerDisplayName: message.senderName,
            storedDisplayName: person.displayName
        )
    }
    
    private func formatDate(_ date: Date) -> String {
        return TimestampFormatter.format(date)
    }
}
