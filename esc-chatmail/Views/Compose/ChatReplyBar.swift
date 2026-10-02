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
    @Binding var isProcessingAttachments: Bool
    @Binding var unavailableReplyTargetURI: URL?
    var recoveredReplyEnvelope: StoredReplyEnvelope? = nil
    @Environment(\.managedObjectContext) private var viewContext
    
    var canSend: Bool {
        unavailableReplyTargetURI == nil && Self.isSendEnabled(
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
    
    private var header: ReplyIndicatorPolicy.Header {
        ReplyIndicatorPolicy.header(
            isReplyTargetUnavailable: unavailableReplyTargetURI != nil,
            recoveredRecipients: recoveredReplyEnvelope?.recipients,
            replyTarget: replyingTo.map { message in
                ReplyIndicatorPolicy.ReplyTarget(
                    subject: message.subject,
                    cleanedSnippet: message.cleanedSnippet,
                    snippet: message.snippet
                )
            }
        )
    }

    private var allowsDraftMutation: Bool {
        ChatReplyBarControlPolicy.allowsDraftMutation(isSending: isSending)
    }

    // No bar-wide `.disabled(isSending)`: see ChatReplyBarControlPolicy. Only
    // the controls that mutate the draft's attachments or destination wait.
    var body: some View {
        VStack(spacing: 0) {
            switch header {
            case .unavailableTarget:
                HStack {
                    Text("Original reply target unavailable")
                    Spacer()
                    Button("Clear target") { unavailableReplyTargetURI = nil }
                        .disabled(!allowsDraftMutation)
                }
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            case .recoveredEnvelope(let label):
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            case .replyingTo(let label):
                replyingToIndicator(label: label)
            case .none:
                EmptyView()
            }
            
            if !attachments.isEmpty {
                attachmentStrip
            }
            
            HStack(alignment: .bottom, spacing: 8) {
                AttachmentPicker(
                    attachments: $attachments,
                    isProcessing: $isProcessingAttachments
                )
                .disabled(!allowsDraftMutation)
                
                textField
                
                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(UIColor.systemBackground))
        }
    }
    
    @ViewBuilder
    private func replyingToIndicator(label: String) -> some View {
        HStack {
            Image(systemName: "arrow.turn.up.left")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(label)
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
            .disabled(!allowsDraftMutation)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.1))
    }
    
    @ViewBuilder
    private var textField: some View {
        PlaceholderTextField(text: $replyText, placeholder: "iMessage")
            .focused(focusBinding)
            .disabled(!ChatReplyBarControlPolicy.isTextFieldEnabled(isSending: isSending))
    }
    
    @ViewBuilder
    private var attachmentStrip: some View {
        AttachmentPreviewStrip(attachments: attachments) { attachment in
            DraftAttachmentThumbnail(attachment: attachment) {
                removeAttachment(attachment)
            }
            .disabled(!allowsDraftMutation)
        }
    }
    
    @ViewBuilder
    private var sendButton: some View {
        SendButton(
            isEnabled: canSend,
            isSending: isSending,
            showsProgress: ChatReplyBarControlPolicy.sendButtonShowsProgress
        ) {
            if canSend {
                Task {
                    _ = await onSend()
                }
            }
        }
    }
    
    private func removeAttachment(_ attachment: Attachment) {
        guard allowsDraftMutation else { return }
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
