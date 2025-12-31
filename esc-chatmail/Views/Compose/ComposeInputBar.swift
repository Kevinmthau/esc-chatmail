import SwiftUI

/// Message-style input bar with attachment strip, text field, and send button
/// Extracted from ComposeView for better separation of concerns
struct ComposeInputBar: View {
    @ObservedObject var viewModel: ComposeViewModel
    var focusedField: FocusState<ComposeView.FocusField?>.Binding
    @Binding var showingAttachmentPicker: Bool
    let onSendSuccess: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.attachments.isEmpty {
                AttachmentPreviewStrip(attachments: viewModel.attachments) { attachment in
                    ComposeAttachmentThumbnail(attachment: attachment) {
                        viewModel.removeAttachment(attachment)
                    }
                }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 12) {
                Button(action: { showingAttachmentPicker = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.gray)
                }

                PlaceholderTextField(text: $viewModel.body, placeholder: "iMessage")
                    .focused(focusedField, equals: .body)

                SendButton(isEnabled: viewModel.canSend, isSending: viewModel.isSending) {
                    Task {
                        if await viewModel.send() {
                            onSendSuccess()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
        }
    }
}
