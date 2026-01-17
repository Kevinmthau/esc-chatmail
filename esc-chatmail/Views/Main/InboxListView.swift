import SwiftUI
import CoreData

struct InboxListView: View {
    @FetchRequest private var messages: FetchedResults<Message>

    init() {
        let request = NSFetchRequest<Message>(entityName: "Message")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Message.internalDate, ascending: false)]
        // Only show inbox messages that are not drafts
        request.predicate = NSPredicate(format: "ANY labels.id == %@ AND NOT (ANY labels.id == %@)", "INBOX", "DRAFT")
        request.fetchBatchSize = 25  // Load messages in batches for better performance
        _messages = FetchRequest(fetchRequest: request)
    }
    
    @StateObject private var messageActions = MessageActions()
    @State private var searchText = ""
    @State private var selectedMessage: Message?
    @State private var showingWebView = false
    @State private var showingComposer = false
    @State private var cachedFilteredMessages: [Message] = []
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(cachedFilteredMessages) { message in
                    MessageRow(message: message)
                        .onTapGesture {
                            selectedMessage = message
                            showingWebView = true
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
            .sheet(isPresented: $showingWebView) {
                if let message = selectedMessage {
                    HTMLMessageView(message: message)
                }
            }
            .sheet(isPresented: $showingComposer) {
                ComposeView(mode: .newMessage)
            }
            .onAppear {
                updateFilteredMessages()
            }
            .onChange(of: messages.count) { _, _ in
                updateFilteredMessages()
            }
            .onChange(of: searchText) { _, _ in
                updateFilteredMessages()
            }
        }
    }

    /// Updates the cached filtered messages when dependencies change.
    /// Caching prevents recalculation on every view body evaluation.
    private func updateFilteredMessages() {
        if searchText.isEmpty {
            cachedFilteredMessages = Array(messages)
        } else {
            cachedFilteredMessages = messages.filter { message in
                message.subject?.localizedCaseInsensitiveContains(searchText) ?? false ||
                message.snippet?.localizedCaseInsensitiveContains(searchText) ?? false
            }
        }
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
        return fromParticipant?.person?.displayName ?? fromParticipant?.person?.email ?? "Unknown"
    }
    
    private func formatDate(_ date: Date) -> String {
        return TimestampFormatter.format(date)
    }
}