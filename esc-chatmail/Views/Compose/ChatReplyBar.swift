import SwiftUI
import CoreData

struct ChatReplyBar: View {
    @Binding var replyText: String
    @Binding var replyingTo: Message?
    @Binding var attachments: [Attachment]
    let conversation: Conversation
    let onSend: () async -> Bool
    var focusBinding: FocusState<Bool>.Binding
    @State private var isSending = false
    @Environment(\.managedObjectContext) private var viewContext
    
    var canSend: Bool {
        (!replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && !isSending
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if let replyingTo = replyingTo,
               let subject = replyingTo.subject,
               !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        PlaceholderTextField(text: $replyText, placeholder: "iMessage")
            .focused(focusBinding)
    }
    
    @ViewBuilder
    private var attachmentStrip: some View {
        AttachmentPreviewStrip(attachments: attachments) { attachment in
            AttachmentThumbnail(attachment: attachment) {
                removeAttachment(attachment)
            }
        }
    }
    
    @ViewBuilder
    private var sendButton: some View {
        SendButton(isEnabled: canSend, isSending: isSending) {
            if canSend {
                Task {
                    isSending = true
                    _ = await onSend()
                    isSending = false
                }
            }
        }
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
    @StateObject private var thumbnailLoader = AttachmentThumbnailLoader()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Thumbnail
            if let image = thumbnailLoader.image {
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
                        Image(systemName: attachment.isPDF ? "doc.fill" : "photo")
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
            thumbnailLoader.load(attachmentId: attachment.id, previewPath: attachment.previewURL)
        }
        .onDisappear {
            thumbnailLoader.cancel()
        }
        .onChange(of: attachment.previewURL) { _, newValue in
            if newValue != nil && thumbnailLoader.image == nil {
                thumbnailLoader.reset()
                thumbnailLoader.load(attachmentId: attachment.id, previewPath: newValue)
            }
        }
    }
}
