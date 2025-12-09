import SwiftUI
import WebKit
import CoreData

struct ChatView: View {
    @ObservedObject var conversation: Conversation

    @FetchRequest private var messages: FetchedResults<Message>
    @StateObject private var messageActions = MessageActions()
    @StateObject private var sendService: GmailSendService
    @ObservedObject private var keyboard = KeyboardResponder.shared
    @State private var selectedMessage: Message?
    @State private var replyText = ""
    @State private var replyingTo: Message?
    @FocusState private var isTextFieldFocused: Bool
    @Namespace private var bottomID
    
    init(conversation: Conversation) {
        self.conversation = conversation

        let request = NSFetchRequest<Message>(entityName: "Message")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Message.internalDate, ascending: true)]
        // Exclude draft messages from the conversation view
        request.predicate = NSPredicate(format: "conversation == %@ AND NOT (ANY labels.id == %@)", conversation, "DRAFTS")
        request.fetchBatchSize = 30  // Load messages in batches for better performance
        self._messages = FetchRequest(fetchRequest: request)

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
                .padding(.bottom, 80)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Dismiss keyboard when tapping empty space
                    isTextFieldFocused = false
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                markConversationAsRead()
                // Delay initial scroll to ensure messages are loaded
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        // Try to scroll to last message or bottom anchor
                        if let lastMessage = messages.last {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        } else {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
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
        // Immediately clear the unread count to remove the indicator
        let context = conversation.managedObjectContext ?? CoreDataStack.shared.viewContext
        conversation.inboxUnreadCount = 0

        do {
            try context.save()
        } catch {
            print("Failed to save conversation unread count: \(error)")
        }

        // Then mark individual messages as read
        Task {
            let unreadMessages = messages.filter { $0.isUnread }
            for message in unreadMessages {
                try? await messageActions.markAsRead(message: message)
            }
            // Update the conversation's unread count again after marking messages
            await MainActor.run {
                conversation.inboxUnreadCount = 0
                try? context.save()
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
        do {
            try CoreDataStack.shared.save(context: CoreDataStack.shared.viewContext)
        } catch {
            print("Failed to toggle pin: \(error)")
            // Revert change on failure
            conversation.pinned.toggle()
        }
    }
    
    private func toggleMute() {
        conversation.muted.toggle()
        do {
            try CoreDataStack.shared.save(context: CoreDataStack.shared.viewContext)
        } catch {
            print("Failed to toggle mute: \(error)")
            // Revert change on failure
            conversation.muted.toggle()
        }
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
        
        let optimisticMessageID = await MainActor.run {
            let message = sendService.createOptimisticMessage(
                to: replyData.recipients,
                body: replyText,
                subject: replyData.subject,
                threadId: replyData.threadId,
                attachments: attachments
            )
            return message.id
        }
        
        
        do {
            let result: GmailSendService.SendResult

            // Convert attachments to AttachmentInfo
            let attachmentInfos = await MainActor.run {
                attachments.map { sendService.attachmentToInfo($0) }
            }

            if let subject = replyData.subject {
                result = try await sendService.sendReply(
                    to: replyData.recipients,
                    body: replyText,
                    subject: subject,
                    threadId: replyData.threadId ?? "",
                    inReplyTo: replyData.inReplyTo,
                    references: replyData.references,
                    originalMessage: replyData.originalMessage,
                    attachmentInfos: attachmentInfos
                )
            } else {
                result = try await sendService.sendNew(
                    to: replyData.recipients,
                    body: replyText,
                    attachmentInfos: attachmentInfos
                )
            }
            
            await MainActor.run {
                if let optimisticMessage = sendService.fetchMessage(byID: optimisticMessageID) {
                    sendService.updateOptimisticMessage(optimisticMessage, with: result)
                }
                // Mark attachments as uploaded after successful send
                if !attachments.isEmpty {
                    sendService.markAttachmentsAsUploaded(attachments)
                }
                replyText = ""
                replyingTo = nil
            }
            
            // Trigger sync to fetch the sent message from Gmail
            Task.detached {
                try? await SyncEngine.shared.performIncrementalSync()
            }
        } catch {
            await MainActor.run {
                if let optimisticMessage = sendService.fetchMessage(byID: optimisticMessageID) {
                    sendService.deleteOptimisticMessage(optimisticMessage)
                }
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
    @State private var fullTextContent: String?

    private let htmlContentHandler = HTMLContentHandler()
    
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

                // For newsletters/promotional emails, show HTML preview
                if message.isNewsletter {
                    VStack(alignment: .leading, spacing: 8) {
                        HTMLPreviewView(message: message, maxHeight: 200)
                            .frame(maxWidth: 260)
                            .onTapGesture {
                                showingHTMLView = true
                            }

                        Button(action: {
                            showingHTMLView = true
                        }) {
                            HStack(spacing: 4) {
                                Text("View Full Email")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Image(systemName: "arrow.up.forward")
                                    .font(.caption2)
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                } else {
                    // For regular emails, show the full text content
                    // Text content - use fullTextContent if loaded, otherwise bodyText, fallback to snippet
                    if let rawText = fullTextContent ?? (message.value(forKey: "bodyText") as? String) ?? message.cleanedSnippet ?? message.snippet, !rawText.isEmpty {
                        let text = stripQuotedText(from: rawText)
                        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 8) {
                            Text(text)
                                .padding(10)
                                .background(message.isFromMe ? Color.blue : Color.gray.opacity(0.2))
                                .foregroundColor(message.isFromMe ? .white : .primary)
                                .cornerRadius(12)

                            // HTML preview for rich content
                            if hasRichContent {
                                VStack(alignment: .leading, spacing: 6) {
                                    HTMLPreviewView(message: message, maxHeight: 150)
                                        .frame(maxWidth: 260)
                                        .onTapGesture {
                                            showingHTMLView = true
                                        }

                                    Button(action: {
                                        showingHTMLView = true
                                    }) {
                                        HStack(spacing: 4) {
                                            Text("View Full Email")
                                                .font(.caption)
                                                .fontWeight(.medium)
                                            Image(systemName: "arrow.up.forward")
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
            await loadFullTextContent()
            checkForRichContent()
        }
        .sheet(isPresented: $showingHTMLView) {
            HTMLMessageView(message: message)
        }
    }
    
    private var isGroupConversation: Bool {
        conversation.conversationType == .group || conversation.conversationType == .list
    }
    
    private func loadFullTextContent() async {
        // Try to load the full text content from HTML if available
        let messageId = message.id

        // Check if HTML file exists
        if htmlContentHandler.htmlFileExists(for: messageId),
           let html = htmlContentHandler.loadHTML(for: messageId) {
            // Extract plain text from HTML
            let plainText = extractPlainText(from: html)
            if !plainText.isEmpty {
                fullTextContent = plainText
                return
            }
        }

        // Otherwise use bodyText if available
        fullTextContent = message.value(forKey: "bodyText") as? String
    }

    private func extractPlainText(from html: String) -> String {
        // Simple HTML to plain text conversion
        var text = html

        // Remove script and style tags and their content
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression, range: nil)

        // Convert common block elements to newlines
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "</div>", with: "\n", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "</h[1-6]>", with: "\n\n", options: .regularExpression, range: nil)

        // Remove all HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)

        // Decode HTML entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")

        // Clean up excessive whitespace
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression, range: nil)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text
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
        // Start with false by default
        hasRichContent = false

        // Never show View More for sent messages - always show full content
        if message.isFromMe {
            return
        }

        // Check if message is a forwarded email - always show View More for these
        if message.isForwardedEmail {
            hasRichContent = true
            return
        }

        // Check if we have HTML content stored
        if let urlString = message.bodyStorageURI,
           let _ = URL(string: urlString) {
            let htmlHandler = HTMLContentHandler()
            let messageId = message.id

            // Only show View More if HTML exists AND can be loaded AND is not simple
            if htmlHandler.htmlFileExists(for: messageId),
               let html = htmlHandler.loadHTML(for: messageId) {
                let complexity = HTMLSanitizerService.shared.analyzeComplexity(html)
                // Only show View More for moderate to complex HTML (not simple)
                hasRichContent = complexity != .simple
            }
        }
    }

    private func stripQuotedText(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var newMessageLines: [String] = []

        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Stop at common quoted text markers
            if trimmedLine.starts(with: ">") ||
               (trimmedLine.starts(with: "On ") && trimmedLine.contains("wrote:")) ||
               (trimmedLine.starts(with: "From:") && index > 0) ||
               trimmedLine == "..." ||
               trimmedLine.contains("---------- Forwarded message ---------") ||
               trimmedLine.contains("________________________________") {
                break
            }

            newMessageLines.append(line)
        }

        return newMessageLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}