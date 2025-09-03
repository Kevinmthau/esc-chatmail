import SwiftUI
import CoreData

struct ChatReplyBar: View {
    @Binding var replyText: String
    @Binding var replyingTo: Message?
    let conversation: Conversation
    let onSend: () async -> Void
    @FocusState private var isTextFieldFocused: Bool
    @State private var isSending = false
    
    var canSend: Bool {
        !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if let replyingTo = replyingTo {
                replyingToIndicator(message: replyingTo)
            }
            
            HStack(alignment: .bottom, spacing: 12) {
                textField
                
                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(UIColor.systemBackground))
        }
    }
    
    @ViewBuilder
    private func replyingToIndicator(message: Message) -> some View {
        HStack {
            Image(systemName: "arrow.turn.up.left")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            
            Text("Replying to: \(message.subject ?? message.snippet ?? "")")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
            
            Spacer()
            
            Button(action: {
                withAnimation(.easeOut(duration: 0.2)) {
                    replyingTo = nil
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.1))
    }
    
    @ViewBuilder
    private var textField: some View {
        ZStack(alignment: .leading) {
            if replyText.isEmpty {
                Text("iMessage")
                    .foregroundColor(.gray.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            
            TextEditor(text: $replyText)
                .focused($isTextFieldFocused)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minHeight: 36, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.gray.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.gray.opacity(0.3), lineWidth: 0.5)
        )
    }
    
    @ViewBuilder
    private var sendButton: some View {
        Button(action: {
            if canSend {
                Task {
                    isSending = true
                    await onSend()
                    isSending = false
                }
            }
        }) {
            ZStack {
                Circle()
                    .fill(canSend ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(width: 32, height: 32)
                
                if isSending {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                }
            }
        }
        .disabled(!canSend)
        .animation(.easeInOut(duration: 0.2), value: canSend)
    }
}

extension ChatReplyBar {
    struct ReplyData {
        let recipients: [String]
        let body: String
        let subject: String?
        let threadId: String?
        let inReplyTo: String?
        let references: [String]
        
        init(from conversation: Conversation, replyingTo: Message?, body: String, currentUserEmail: String) {
            // Extract participants from conversation participants relationship
            let participantEmails = Array(conversation.participants ?? [])
                .compactMap { $0.person?.email }
            let allParticipants = participantEmails
            self.recipients = allParticipants.filter { EmailNormalizer.normalize($0) != EmailNormalizer.normalize(currentUserEmail) }
            self.body = body
            
            if let replyingTo = replyingTo {
                self.subject = replyingTo.subject.map { MimeBuilder.prefixSubjectForReply($0) }
                self.threadId = replyingTo.gmThreadId
                self.inReplyTo = nil // Message ID not stored in current model
                self.references = [] // References not stored in current model
            } else {
                let latestMessage = Array(conversation.messages ?? [])
                    .sorted { $0.internalDate > $1.internalDate }
                    .first
                
                self.subject = nil
                self.threadId = latestMessage?.gmThreadId
                self.inReplyTo = nil
                self.references = []
            }
        }
    }
}