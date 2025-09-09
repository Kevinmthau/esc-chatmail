import SwiftUI

struct MessageContextMenu: ViewModifier {
    let message: Message
    @Binding var replyingTo: Message?
    
    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        replyingTo = message
                    }
                }) {
                    SwiftUI.Label("Reply", systemImage: "arrow.turn.up.left")
                }
                
                if let snippet = message.snippet {
                    Button(action: {
                        UIPasteboard.general.string = snippet
                    }) {
                        SwiftUI.Label("Copy", systemImage: "doc.on.doc")
                    }
                }
                
                if message.hasAttachments {
                    Button(action: {}) {
                        SwiftUI.Label("Save Attachments", systemImage: "square.and.arrow.down")
                    }
                    .disabled(true)
                }
                
                Divider()
                
                Button(action: {}) {
                    SwiftUI.Label("Forward", systemImage: "arrow.turn.up.right")
                }
                .disabled(true)
                
                Button(role: .destructive, action: {}) {
                    SwiftUI.Label("Delete", systemImage: "trash")
                }
                .disabled(true)
            }
    }
}

extension View {
    func messageContextMenu(message: Message, replyingTo: Binding<Message?>) -> some View {
        self.modifier(MessageContextMenu(message: message, replyingTo: replyingTo))
    }
}

struct EnhancedMessageBubble: View {
    let message: Message
    @Binding var replyingTo: Message?
    @State private var isPressed = false
    
    var body: some View {
        HStack {
            if message.isFromMe {
                Spacer(minLength: 60)
            }
            
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                if let subject = message.subject, !subject.isEmpty {
                    Text(subject)
                        .font(.caption.weight(.medium))
                        .foregroundColor(message.isFromMe ? .white.opacity(0.9) : .secondary)
                }
                
                Text(message.snippet ?? "")
                    .font(.body)
                    .foregroundColor(message.isFromMe ? .white : .primary)
                    .multilineTextAlignment(message.isFromMe ? .trailing : .leading)
                
                Text(formatMessageTime(message.internalDate))
                    .font(.caption2)
                    .foregroundColor(message.isFromMe ? .white.opacity(0.7) : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(message.isFromMe ? Color.blue : Color.gray.opacity(0.15))
            )
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .messageContextMenu(message: message, replyingTo: $replyingTo)
            .onLongPressGesture(minimumDuration: 0.5, maximumDistance: .infinity, pressing: { pressing in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isPressed = pressing
                }
            }, perform: {})
            
            if !message.isFromMe {
                Spacer(minLength: 60)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .id(message.id)
    }
    
    private func formatMessageTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'Yesterday' h:mm a"
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            formatter.dateFormat = "EEEE h:mm a"
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
        }
        
        return formatter.string(from: date)
    }
}

struct EnhancedChatView: View {
    let conversation: Conversation
    @StateObject private var sendService: GmailSendService
    @State private var replyText = ""
    @State private var replyingTo: Message?
    @State private var scrollToMessageId: String?
    @FocusState private var isReplyFieldFocused: Bool
    
    init(conversation: Conversation) {
        self.conversation = conversation
        self._sendService = StateObject(wrappedValue: GmailSendService(
            viewContext: CoreDataStack.shared.viewContext
        ))
    }
    
    private var sortedMessages: [Message] {
        Array(conversation.messages ?? [])
            .sorted { $0.internalDate < $1.internalDate }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sortedMessages, id: \.id) { message in
                            EnhancedMessageBubble(message: message, replyingTo: $replyingTo)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: scrollToMessageId) { _, messageId in
                    if let messageId = messageId {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(messageId, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            ChatReplyBar(
                replyText: $replyText,
                replyingTo: $replyingTo,
                conversation: conversation,
                onSend: { attachments in
                    await sendReply(with: attachments)
                }
            )
            .background(Color(UIColor.systemBackground))
        }
        .navigationTitle(conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let lastMessage = sortedMessages.last {
                scrollToMessageId = lastMessage.id
            }
        }
    }
    
    private var conversationTitle: String {
        let participantEmails = Array(conversation.participants ?? [])
            .compactMap { $0.person?.email }
        let otherParticipants = participantEmails.filter {
            EmailNormalizer.normalize($0) != EmailNormalizer.normalize(AuthSession.shared.userEmail ?? "")
        }
        
        if otherParticipants.count == 1 {
            return otherParticipants.first ?? "Chat"
        } else if otherParticipants.count > 1 {
            return "\(otherParticipants.count) recipients"
        }
        return "Chat"
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
                scrollToMessageId = optimisticMessage.id
            }
        } catch {
            await MainActor.run {
                sendService.deleteOptimisticMessage(optimisticMessage)
                print("Failed to send reply: \(error)")
            }
        }
    }
}