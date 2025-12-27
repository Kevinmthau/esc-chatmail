import SwiftUI
import CoreData

struct ChatReplyBar: View {
    @Binding var replyText: String
    @Binding var replyingTo: Message?
    let conversation: Conversation
    let onSend: ([Attachment]) async -> Void
    var focusBinding: FocusState<Bool>.Binding
    @State private var isSending = false
    @State private var attachments: [Attachment] = []
    @Environment(\.managedObjectContext) private var viewContext
    
    var canSend: Bool {
        (!replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && !isSending
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if let replyingTo = replyingTo {
                replyingToIndicator(message: replyingTo)
            }
            
            if !attachments.isEmpty {
                attachmentStrip
            }
            
            HStack(alignment: .bottom, spacing: 8) {
                AttachmentPicker(attachments: $attachments)
                
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
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("Replying to: \(message.subject ?? message.snippet ?? "")")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            
            Spacer()
            
            Button(action: {
                withAnimation(.easeOut(duration: 0.2)) {
                    replyingTo = nil
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
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
                .focused(focusBinding)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minHeight: 36, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture {
                    focusBinding.wrappedValue = true
                }
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
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentThumbnail(attachment: attachment) {
                        removeAttachment(attachment)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color.gray.opacity(0.05))
    }
    
    @ViewBuilder
    private var sendButton: some View {
        Button(action: {
            if canSend {
                Task {
                    isSending = true
                    await onSend(attachments)
                    attachments = []
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
                        .font(.callout.weight(.bold))
                        .foregroundColor(.white)
                }
            }
        }
        .disabled(!canSend)
        .animation(.easeInOut(duration: 0.2), value: canSend)
    }
    
    private func removeAttachment(_ attachment: Attachment) {
        if let index = attachments.firstIndex(of: attachment) {
            let removed = attachments.remove(at: index)
            
            // Clean up files if it's a local attachment
            if removed.isLocalAttachment {
                if let localURL = removed.localURL {
                    AttachmentPaths.deleteFile(at: localURL)
                }
                if let previewURL = removed.previewURL {
                    AttachmentPaths.deleteFile(at: previewURL)
                }
            }
            
            viewContext.delete(removed)
        }
    }
}

struct AttachmentThumbnail: View {
    let attachment: Attachment
    let onRemove: () -> Void
    @State private var thumbnailImage: UIImage?
    private let cache = AttachmentCache.shared
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Thumbnail
            if let image = thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: isPDF(attachment) ? "doc.fill" : "photo")
                            .foregroundColor(.gray)
                    )
            }
            
            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .offset(x: 4, y: -4)
        }
        .onAppear {
            loadThumbnail()
        }
    }
    
    private func loadThumbnail() {
        guard thumbnailImage == nil,
              let attachmentId = attachment.id else { return }

        Task {
            if let image = await cache.loadThumbnail(for: attachmentId, from: attachment.previewURL) {
                await MainActor.run {
                    self.thumbnailImage = image
                }
            }
        }
    }

    private func isPDF(_ attachment: Attachment) -> Bool {
        attachment.isPDF
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
        let attachments: [Attachment]
        let originalMessage: QuotedMessage?
        
        init(from conversation: Conversation, replyingTo: Message?, body: String, attachments: [Attachment], currentUserEmail: String) {
            // Extract participants from conversation participants relationship
            let participantEmails = Array(conversation.participants ?? [])
                .compactMap { $0.person?.email }
            let allParticipants = participantEmails
            self.recipients = allParticipants.filter { EmailNormalizer.normalize($0) != EmailNormalizer.normalize(currentUserEmail) }
            self.body = body
            self.attachments = attachments
            
            if let replyingTo = replyingTo {
                self.subject = replyingTo.subject.map { MimeBuilder.prefixSubjectForReply($0) }
                self.threadId = replyingTo.gmThreadId
                self.inReplyTo = replyingTo.messageId

                // Build references chain from previous references + message ID
                var refs: [String] = []
                if let previousRefs = replyingTo.references, !previousRefs.isEmpty {
                    refs = previousRefs.split(separator: " ").map(String.init)
                }
                if let messageId = replyingTo.messageId {
                    refs.append(messageId)
                }
                self.references = refs

                // Store original message info for quoting
                self.originalMessage = QuotedMessage(
                    senderName: replyingTo.senderName,
                    senderEmail: replyingTo.senderEmail ?? "",
                    date: replyingTo.internalDate,
                    body: replyingTo.bodyText
                )
            } else {
                let latestMessage = Array(conversation.messages ?? [])
                    .sorted { $0.internalDate > $1.internalDate }
                    .first

                self.subject = nil
                self.threadId = latestMessage?.gmThreadId
                self.inReplyTo = nil
                self.references = []
                self.originalMessage = nil
            }
        }
    }
}