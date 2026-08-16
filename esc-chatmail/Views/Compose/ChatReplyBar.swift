import SwiftUI
import CoreData

struct ChatReplyBar: View {
    @Binding var replyText: String
    @Binding var replyingTo: Message?
    @Binding var attachments: [Attachment]
    let conversation: Conversation
    let isSending: Bool
    let onSend: () async -> Bool
    var focusBinding: FocusState<Bool>.Binding
    @State private var isProcessingAttachments = false
    @Environment(\.managedObjectContext) private var viewContext
    
    var canSend: Bool {
        Self.isSendEnabled(
            replyText: replyText,
            hasAttachments: !attachments.isEmpty,
            isSending: isSending,
            isProcessingAttachments: isProcessingAttachments
        )
    }

    static func isSendEnabled(
        replyText: String,
        hasAttachments: Bool,
        isSending: Bool,
        isProcessingAttachments: Bool
    ) -> Bool {
        let hasContent = !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments
        return hasContent && !isSending && !isProcessingAttachments
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
                AttachmentPicker(
                    attachments: $attachments,
                    isProcessing: $isProcessingAttachments
                )
                
                textField
                
                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(UIColor.systemBackground))
        }
        .disabled(isSending)
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
            DraftAttachmentThumbnail(attachment: attachment) {
                removeAttachment(attachment)
            }
        }
    }
    
    @ViewBuilder
    private var sendButton: some View {
        SendButton(isEnabled: canSend, isSending: isSending) {
            if canSend {
                Task {
                    _ = await onSend()
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
