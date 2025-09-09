import SwiftUI
import WebKit
import CoreData

struct ChatView: View {
    let conversation: Conversation
    
    @FetchRequest private var messages: FetchedResults<Message>
    @StateObject private var messageActions = MessageActions()
    @StateObject private var sendService: GmailSendService
    @State private var selectedMessage: Message?
    @State private var showingWebView = false
    @State private var replyText = ""
    @State private var replyingTo: Message?
    @State private var scrollToMessage: String?
    
    init(conversation: Conversation) {
        self.conversation = conversation
        self._messages = FetchRequest(
            entity: Message.entity(),
            sortDescriptors: [NSSortDescriptor(keyPath: \Message.internalDate, ascending: true)],
            predicate: NSPredicate(format: "conversation == %@", conversation)
        )
        self._sendService = StateObject(wrappedValue: GmailSendService(
            viewContext: CoreDataStack.shared.viewContext
        ))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { message in
                            MessageBubble(message: message, conversation: conversation)
                                .id(message.id)
                                .onTapGesture {
                                    selectedMessage = message
                                    showingWebView = true
                                }
                                .contextMenu {
                                    messageContextMenu(for: message)
                                }
                        }
                    }
                    .padding()
                }
                .onAppear {
                    markConversationAsRead()
                    if let lastMessage = messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
                .onChange(of: scrollToMessage) { _, messageId in
                    if let messageId = messageId {
                        withAnimation {
                            proxy.scrollTo(messageId, anchor: .bottom)
                        }
                        // Reset after scrolling
                        scrollToMessage = nil
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    // Scroll to bottom when new messages appear
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            ChatReplyBar(
                replyText: $replyText,
                replyingTo: $replyingTo,
                conversation: conversation,
                onSend: {
                    await sendReply()
                }
            )
        }
        .navigationTitle(conversation.displayName ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { archiveConversation() }) {
                            SwiftUI.Label("Archive", systemImage: "archivebox")
                        }
                        
                        Button(action: { togglePin() }) {
                            SwiftUI.Label(conversation.pinned ? "Unpin" : "Pin",
                                  systemImage: conversation.pinned ? "pin.slash" : "pin")
                        }
                        
                        Button(action: { toggleMute() }) {
                            SwiftUI.Label(conversation.muted ? "Unmute" : "Mute",
                                  systemImage: conversation.muted ? "bell" : "bell.slash")
                        }
                        
                        Button(role: .destructive, action: { deleteConversation() }) {
                            SwiftUI.Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingWebView) {
                if let message = selectedMessage {
                    MessageWebView(message: message)
                }
            }
    }
    
    @ViewBuilder
    private func messageContextMenu(for message: Message) -> some View {
        Button(action: { 
            replyingTo = message
        }) {
            SwiftUI.Label("Reply", systemImage: "arrow.turn.up.left")
        }
        
        Button(action: { toggleMessageRead(message) }) {
            SwiftUI.Label(message.isUnread ? "Mark as Read" : "Mark as Unread",
                  systemImage: message.isUnread ? "envelope.open" : "envelope")
        }
        
        Button(action: { archiveMessage(message) }) {
            SwiftUI.Label("Archive", systemImage: "archivebox")
        }
        
        Button(action: { starMessage(message) }) {
            SwiftUI.Label("Star", systemImage: "star")
        }
    }
    
    private func markConversationAsRead() {
        Task {
            let unreadMessages = messages.filter { $0.isUnread }
            for message in unreadMessages {
                try? await messageActions.markAsRead(message: message)
            }
        }
    }
    
    private func toggleMessageRead(_ message: Message) {
        Task {
            if message.isUnread {
                try? await messageActions.markAsRead(message: message)
            } else {
                try? await messageActions.markAsUnread(message: message)
            }
        }
    }
    
    private func archiveMessage(_ message: Message) {
        Task {
            try? await messageActions.archive(message: message)
        }
    }
    
    private func archiveConversation() {
        Task {
            try? await messageActions.archiveConversation(conversation: conversation)
        }
    }
    
    private func starMessage(_ message: Message) {
        Task {
            try? await messageActions.star(message: message)
        }
    }
    
    private func togglePin() {
        conversation.pinned.toggle()
        CoreDataStack.shared.save(context: CoreDataStack.shared.viewContext)
    }
    
    private func toggleMute() {
        conversation.muted.toggle()
        CoreDataStack.shared.save(context: CoreDataStack.shared.viewContext)
    }
    
    private func deleteConversation() {
        Task {
            try? await messageActions.deleteConversation(conversation: conversation)
        }
    }
    
    private func sendReply() async {
        guard !replyText.isEmpty else { return }
        
        let replyData = ChatReplyBar.ReplyData(
            from: conversation,
            replyingTo: replyingTo,
            body: replyText,
            currentUserEmail: AuthSession.shared.userEmail ?? ""
        )
        
        guard !replyData.recipients.isEmpty else { return }
        
        let optimisticMessage = await MainActor.run {
            sendService.createOptimisticMessage(
                to: replyData.recipients,
                body: replyText,
                subject: replyData.subject,
                threadId: replyData.threadId
            )
        }
        
        
        do {
            let result: GmailSendService.SendResult
            
            if let subject = replyData.subject {
                result = try await sendService.sendReply(
                    to: replyData.recipients,
                    body: replyText,
                    subject: subject,
                    threadId: replyData.threadId ?? "",
                    inReplyTo: replyData.inReplyTo,
                    references: replyData.references
                )
            } else {
                result = try await sendService.sendNew(
                    to: replyData.recipients,
                    body: replyText
                )
            }
            
            await MainActor.run {
                sendService.updateOptimisticMessage(optimisticMessage, with: result)
                replyText = ""
                replyingTo = nil
                // Scroll to the new message after sending
                scrollToMessage = result.messageId
            }
            
            // Trigger sync to fetch the sent message from Gmail
            Task {
                try? await SyncEngine.shared.performIncrementalSync()
            }
        } catch {
            await MainActor.run {
                sendService.deleteOptimisticMessage(optimisticMessage)
                print("Failed to send reply: \(error)")
            }
        }
    }
}

struct MessageBubble: View {
    let message: Message
    let conversation: Conversation
    @StateObject private var contactsResolver = ContactsResolver.shared
    @State private var senderName: String?
    
    var body: some View {
        HStack {
            if message.isFromMe {
                Spacer()
            }
            
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                // Show sender name for group chats when not from me
                if !message.isFromMe && isGroupConversation && senderName != nil {
                    Text(senderName!)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                }
                
                // Show subject for both sent and received messages
                if let subject = message.subject, !subject.isEmpty {
                    Text(subject)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(message.isFromMe ? .secondary : .primary)
                }
                
                Text(message.cleanedSnippet ?? message.snippet ?? "")
                    .padding(10)
                    .background(message.isFromMe ? Color.blue : Color.gray.opacity(0.2))
                    .foregroundColor(message.isFromMe ? .white : .primary)
                    .cornerRadius(12)
                
                HStack(spacing: 8) {
                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.caption)
                    }
                    
                    if message.isUnread {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                    }
                    
                    Text(formatTime(message.internalDate))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: 280, alignment: message.isFromMe ? .trailing : .leading)
            
            if !message.isFromMe {
                Spacer()
            }
        }
        .task {
            if !message.isFromMe && isGroupConversation {
                await loadSenderName()
            }
        }
    }
    
    private var isGroupConversation: Bool {
        conversation.conversationType == .group || conversation.conversationType == .list
    }
    
    private func loadSenderName() async {
        // Find the 'from' participant
        guard let participants = message.participants else { return }
        
        for participant in participants {
            if participant.participantKind == .from,
               let email = participant.person?.email {
                
                // Try contacts first
                if let match = await contactsResolver.lookup(email: email),
                   let displayName = match.displayName {
                    senderName = displayName
                } else if let personName = participant.person?.displayName,
                          !personName.isEmpty {
                    senderName = personName
                } else {
                    // Extract local part of email
                    let normalized = EmailNormalizer.normalize(email)
                    if let atIndex = normalized.firstIndex(of: "@") {
                        senderName = String(normalized[..<atIndex])
                    } else {
                        senderName = email
                    }
                }
                break
            }
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        return TimestampFormatter.format(date)
    }
}

struct MessageWebView: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Group {
                if let urlString = message.bodyStorageURI,
                   let url = URL(string: urlString) {
                    WebView(url: url)
                } else {
                    Text("No content available")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
    }
}