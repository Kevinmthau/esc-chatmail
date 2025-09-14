import SwiftUI
import CoreData

struct InboxListView: View {
    @FetchRequest(
        entity: Message.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \Message.internalDate, ascending: false)],
        predicate: NSPredicate(format: "ANY labels.id == %@", "INBOX")
    ) private var messages: FetchedResults<Message>
    
    @StateObject private var messageActions = MessageActions()
    @State private var searchText = ""
    @State private var selectedMessage: Message?
    @State private var showingWebView = false
    @State private var showingComposer = false
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredMessages) { message in
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
                NewMessageComposerView()
            }
        }
    }
    
    private var filteredMessages: [Message] {
        if searchText.isEmpty {
            return Array(messages)
        } else {
            return messages.filter { message in
                message.subject?.localizedCaseInsensitiveContains(searchText) ?? false ||
                message.snippet?.localizedCaseInsensitiveContains(searchText) ?? false
            }
        }
    }
    
    private func archiveMessage(_ message: Message) {
        Task {
            try? await messageActions.archive(message: message)
        }
    }
    
    private func toggleRead(_ message: Message) {
        Task {
            if message.isUnread {
                try? await messageActions.markAsRead(message: message)
            } else {
                try? await messageActions.markAsUnread(message: message)
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