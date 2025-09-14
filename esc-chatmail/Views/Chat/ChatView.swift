import SwiftUI
import WebKit
import CoreData

struct ChatView: View {
    let conversation: Conversation
    
    @FetchRequest private var messages: FetchedResults<Message>
    @StateObject private var messageActions = MessageActions()
    @StateObject private var sendService: GmailSendService
    @StateObject private var keyboard = KeyboardResponder()
    @State private var selectedMessage: Message?
    @State private var replyText = ""
    @State private var replyingTo: Message?
    @FocusState private var isTextFieldFocused: Bool
    @Namespace private var bottomID
    
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
                        MessageBubble(message: message, conversation: conversation)
                            .id(message.id)
                            .contextMenu {
                                messageContextMenu(for: message)
                            }
                    }
                    // Bottom anchor for scrolling
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Dismiss keyboard when tapping empty space
                    isTextFieldFocused = false
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                markConversationAsRead()
                // Initial scroll to bottom
                withAnimation {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onChange(of: messages.count) { oldCount, newCount in
                // Scroll to bottom when new messages appear
                if newCount > oldCount {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: keyboard.currentHeight) { oldHeight, newHeight in
                // Scroll to bottom when keyboard appears or disappears
                if newHeight > 0 || (oldHeight > 0 && newHeight == 0) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: isTextFieldFocused) { _, isFocused in
                // Also scroll when focus changes (handles tap dismissal)
                if !isFocused {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Reply bar at bottom
                VStack(spacing: 0) {
                    Divider()
                    ChatReplyBar(
                        replyText: $replyText,
                        replyingTo: $replyingTo,
                        conversation: conversation,
                        onSend: { attachments in
                            await sendReply(with: attachments)
                        },
                        focusBinding: $isTextFieldFocused
                    )
                    .background(Color(UIColor.systemBackground))
                }
            }
        }
        .navigationTitle(conversation.displayName ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Add tap gesture to navigation bar area
                ToolbarItem(placement: .principal) {
                    Text(conversation.displayName ?? "Chat")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isTextFieldFocused = false
                        }
                }
                
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
            .sheet(item: $messageToForward) { message in
                NewMessageView(forwardedMessage: message)
            }
    }
    
    @State private var messageToForward: Message?
    
    @ViewBuilder
    private func messageContextMenu(for message: Message) -> some View {
        Button(action: { 
            replyingTo = message
        }) {
            SwiftUI.Label("Reply", systemImage: "arrow.turn.up.left")
        }
        
        Button(action: { 
            messageToForward = message
        }) {
            SwiftUI.Label("Forward", systemImage: "arrow.turn.up.right")
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
    
    private func sendReply(with attachments: [Attachment]) async {
        guard !replyText.isEmpty || !attachments.isEmpty else { return }
        
        let replyData = ChatReplyBar.ReplyData(
            from: conversation,
            replyingTo: replyingTo,
            body: replyText,
            attachments: attachments,
            currentUserEmail: AuthSession.shared.userEmail ?? ""
        )
        
        guard !replyData.recipients.isEmpty else { return }
        
        let optimisticMessage = await MainActor.run {
            sendService.createOptimisticMessage(
                to: replyData.recipients,
                body: replyText,
                subject: replyData.subject,
                threadId: replyData.threadId,
                attachments: attachments
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
                    references: replyData.references,
                    attachments: attachments
                )
            } else {
                result = try await sendService.sendNew(
                    to: replyData.recipients,
                    body: replyText,
                    attachments: attachments
                )
            }
            
            await MainActor.run {
                sendService.updateOptimisticMessage(optimisticMessage, with: result)
                replyText = ""
                replyingTo = nil
            }
            
            // Trigger sync to fetch the sent message from Gmail
            Task.detached {
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
    @State private var showingHTMLView = false
    @State private var hasRichContent = false
    
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
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundColor(message.isFromMe ? .secondary : .primary)
                }
                
                // Attachments
                if let attachmentSet = message.value(forKey: "attachments") as? NSSet,
                   let attachments = attachmentSet.allObjects as? [Attachment], !attachments.isEmpty {
                    AttachmentGridView(attachments: attachments)
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.65)
                }
                
                // Text content
                if let text = message.cleanedSnippet ?? message.snippet, !text.isEmpty {
                    VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 8) {
                        Text(text)
                            .padding(10)
                            .background(message.isFromMe ? Color.blue : Color.gray.opacity(0.2))
                            .foregroundColor(message.isFromMe ? .white : .primary)
                            .cornerRadius(12)

                        // View More button for rich HTML content
                        if hasRichContent {
                            Button(action: {
                                showingHTMLView = true
                            }) {
                                HStack(spacing: 4) {
                                    Text("View More")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.caption2)
                                }
                                .foregroundColor(.blue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
                
                HStack(spacing: 8) {
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
            checkForRichContent()
        }
        .sheet(isPresented: $showingHTMLView) {
            HTMLMessageView(message: message)
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

    private func checkForRichContent() {
        // Check if we have HTML content stored
        if let urlString = message.bodyStorageURI,
           let _ = URL(string: urlString) {
            // Check if HTML file exists
            let htmlHandler = HTMLContentHandler()
            let messageId = message.id
            hasRichContent = htmlHandler.htmlFileExists(for: messageId)

            // Additionally analyze complexity if HTML exists
            if hasRichContent,
               let html = htmlHandler.loadHTML(for: messageId) {
                let complexity = HTMLSanitizerService.shared.analyzeComplexity(html)
                // Only show View More for moderate to complex HTML
                hasRichContent = complexity != .simple
            }
        }
    }
}