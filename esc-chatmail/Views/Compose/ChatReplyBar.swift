import SwiftUI
import CoreData

struct ChatReplyBar: View {
    @Binding var replyText: String
    @Binding var replyingTo: Message?
    @Binding var attachments: [Attachment]
    let conversation: Conversation
    let isSending: Bool
    let onSend: () async -> Bool
    /// The reply field's focus, for whichever field `style` draws (`ChatComposerFocus`).
    let focus: ChatComposerFocus
    /// What the composer draws: the iPhone's bar or the Mac's floating composer
    /// (`ChatComposerPolicy`). The draft, the send and the checks before it are the same.
    let style: ChatComposerStyle
    @Binding var isProcessingAttachments: Bool
    @Binding var unavailableReplyTargetURI: URL?
    var recoveredReplyEnvelope: StoredReplyEnvelope? = nil
    /// Files dropped on the chat, handed to the attachment picker to import
    /// (`ChatComposerState.pendingFileDrop`).
    var fileDrop: Binding<DraftFileDrop?> = .constant(nil)
    @Environment(\.managedObjectContext) private var viewContext
    
    var canSend: Bool {
        canSend(replyText: replyText)
    }

    /// Whether the composer would send `replyText` now. The Mac's field asks this of the text
    /// it holds as Return is pressed (`MacReplyTextField.canSend`).
    private func canSend(replyText: String) -> Bool {
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

    var body: some View {
        if let metrics = ChatComposerPolicy.floatingMetrics(for: style) {
            floatingComposer(metrics: metrics)
        } else {
            bar
        }
    }

    // No bar-wide `.disabled(isSending)`: see ChatReplyBarControlPolicy. Only
    // the controls that mutate the draft's attachments or destination wait.
    private var bar: some View {
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
                    isProcessing: $isProcessingAttachments,
                    fileDrop: fileDrop
                )
                .disabled(!allowsDraftMutation)
                
                textField
                
                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.systemBackground)
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
            
            Button(action: dropQuote) {
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
            .focused(focus.fieldBinding)
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
            sendIfAllowed()
        }
    }

    /// The one way the composer sends, from the send button, the Mac's send arrow and Return
    /// in the Mac's field alike: `onSend`, behind `canSend`.
    private func sendIfAllowed() {
        if canSend {
            Task {
                _ = await onSend()
            }
        }
    }

    /// Drops the quoted message and keeps the reply's destination: the indicator's X, and
    /// Escape in the Mac's field.
    private func dropQuote() {
        withAnimation(.easeOut(duration: 0.2)) {
            replyingTo = nil
        }
    }

    /// The Mac's floating composer (`MacChatReplyBarLayout`), filled from the same draft, the
    /// same header decision and the same send as the bar. The bar itself where there is no
    /// floating composer to draw (iOS, which never asks for one).
    @ViewBuilder
    private func floatingComposer(metrics: ChatComposerMetrics) -> some View {
        #if os(macOS)
        MacChatReplyBarLayout(
            metrics: metrics,
            text: $replyText,
            placeholder: "iMessage",
            showsSendArrow: ChatComposerPolicy.showsSendArrow(
                replyText: replyText,
                hasAttachments: !attachments.isEmpty
            ),
            isSendEnabled: canSend,
            focusBridge: focus.bridge,
            canSend: { canSend(replyText: $0) },
            onSend: sendIfAllowed,
            onCancel: {
                if ChatComposerPolicy.escapeDropsQuote(
                    header: header,
                    allowsDraftMutation: allowsDraftMutation
                ) {
                    dropQuote()
                }
            },
            indicator: {
                MacReplyIndicator(
                    header: header,
                    metrics: metrics,
                    allowsDraftMutation: allowsDraftMutation,
                    onDropQuote: dropQuote,
                    onClearUnavailableTarget: { unavailableReplyTargetURI = nil }
                )
            },
            attachments: {
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachment in
                                DraftAttachmentThumbnail(attachment: attachment) {
                                    removeAttachment(attachment)
                                }
                                .disabled(!allowsDraftMutation)
                            }
                        }
                        // Room for each thumbnail's remove button, which sits past its
                        // top trailing corner and would be clipped by the scroll view.
                        .padding(.top, 4)
                        .padding(.trailing, 4)
                    }
                }
            },
            attachmentMenu: {
                AttachmentPicker(
                    attachments: $attachments,
                    isProcessing: $isProcessingAttachments,
                    style: .plusMenu(diameter: metrics.controlDiameter),
                    fileDrop: fileDrop
                )
                .disabled(!allowsDraftMutation)
            }
        )
        #else
        bar
        #endif
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
