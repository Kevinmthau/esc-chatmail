import SwiftUI
import PhotosUI

/// Message-style input bar with attachment buttons, text field, and send button
struct ComposeInputBar: View {
    enum Style {
        case standard
        case iMessage
    }

    @ObservedObject var viewModel: ComposeViewModel
    var focusedField: FocusState<ComposeView.FocusField?>.Binding
    let onSendSuccess: () -> Void
    let style: Style

    @Environment(\.managedObjectContext) private var viewContext
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var showAttachmentOptions = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isProcessing = false
    @State private var photoProcessingTask: Task<Void, Never>?

    private let maxAttachmentSize: Int64 = 25 * 1024 * 1024 // 25 MB
    private var iMessageButtonBackground: Color {
        Color(uiColor: UIColor(red: 242/255, green: 242/255, blue: 247/255, alpha: 1))
    }

    private var iMessageBorderColor: Color {
        Color.gray.opacity(0.2)
    }

    private var iMessageFieldBackground: Color {
        Color(uiColor: UIColor(red: 241/255, green: 241/255, blue: 246/255, alpha: 1))
    }

    private var hasTypedContent: Bool {
        !viewModel.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !viewModel.attachments.isEmpty
    }

    init(
        viewModel: ComposeViewModel,
        focusedField: FocusState<ComposeView.FocusField?>.Binding,
        onSendSuccess: @escaping () -> Void,
        style: Style = .standard
    ) {
        self.viewModel = viewModel
        self.focusedField = focusedField
        self.onSendSuccess = onSendSuccess
        self.style = style
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.attachments.isEmpty {
                AttachmentPreviewStrip(attachments: viewModel.attachments) { attachment in
                    ComposeAttachmentThumbnail(attachment: attachment) {
                        viewModel.removeAttachment(attachment)
                    }
                }
            }

            Rectangle()
                .fill(iMessageBorderColor)
                .frame(height: 0.75)

            HStack(alignment: .bottom, spacing: style == .iMessage ? 10 : 12) {
                if style == .iMessage {
                    iMessageAttachmentButton
                } else {
                    standardAttachmentButtons
                }

                PlaceholderTextField(
                    text: $viewModel.body,
                    placeholder: "iMessage",
                    lineLimit: style == .iMessage ? 1...4 : 1...5,
                    cornerRadius: style == .iMessage ? 24 : 18,
                    backgroundColor: style == .iMessage ? iMessageFieldBackground : Color(.systemGray6),
                    textFont: style == .iMessage ? .system(size: 18) : .body,
                    horizontalPadding: style == .iMessage ? 16 : 12,
                    verticalPadding: style == .iMessage ? 10 : 8,
                    minHeight: style == .iMessage ? 46 : nil
                )
                    .focused(focusedField, equals: .body)

                if style == .iMessage && !hasTypedContent && !viewModel.isSending {
                    Image(systemName: "mic")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(width: 34, height: 38)
                } else {
                    SendButton(isEnabled: viewModel.canSend && !isProcessing, isSending: viewModel.isSending) {
                        Task {
                            if await viewModel.send() {
                                onSendSuccess()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, style == .iMessage ? 10 : 8)
            .padding(.bottom, style == .iMessage ? 10 : 8)
            .background(Color(.systemBackground))
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 10,
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { oldValue, newValue in
            photoProcessingTask?.cancel()
            photoProcessingTask = Task {
                await processPhotoSelections(newValue)
            }
        }
        .onDisappear {
            photoProcessingTask?.cancel()
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(attachments: Binding(
                get: { viewModel.attachmentManager.attachments },
                set: { viewModel.attachmentManager.attachments = $0 }
            ))
        }
        .confirmationDialog("Add Attachment", isPresented: $showAttachmentOptions) {
            Button("Photo Library") {
                showPhotoPicker = true
            }
            Button("Browse Files") {
                showDocumentPicker = true
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    @ViewBuilder
    private var standardAttachmentButtons: some View {
        Button(action: { showPhotoPicker = true }) {
            Image(systemName: "photo")
                .font(.system(size: 20))
                .foregroundColor(.blue)
        }
        .disabled(isProcessing)
        .accessibilityLabel("Attach photo")

        Button(action: { showDocumentPicker = true }) {
            Image(systemName: "paperclip")
                .font(.system(size: 20))
                .foregroundColor(.blue)
        }
        .disabled(isProcessing)
        .accessibilityLabel("Attach document")
    }

    @ViewBuilder
    private var iMessageAttachmentButton: some View {
        Button {
            showAttachmentOptions = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(.primary)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(iMessageButtonBackground)
                        .overlay(
                            Circle()
                                .strokeBorder(iMessageBorderColor, lineWidth: 0.6)
                        )
                )
        }
        .disabled(isProcessing)
        .accessibilityLabel("Add attachment")
    }

    private func processPhotoSelections(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isProcessing = true
        defer { isProcessing = false }

        let placeholderIds = await MainActor.run { () -> [String] in
            items.enumerated().map { index, _ in
                let localId = "local_\(UUID().uuidString)"
                let attachment = Attachment(context: viewContext)
                attachment.id = localId
                attachment.filename = "photo_\(Int(Date().timeIntervalSince1970))_\(index).jpg"
                attachment.mimeType = "image/jpeg"
                attachment.stateRaw = Attachment.State.queued.rawValue
                viewModel.addAttachment(attachment)
                return localId
            }
        }

        for (item, localId) in zip(items, placeholderIds) {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                removeAttachmentPlaceholder(localId: localId)
                continue
            }

            // Process image
            let (processedData, size) = ImageProcessor.processImage(data: data)
            guard let finalData = processedData else {
                removeAttachmentPlaceholder(localId: localId)
                continue
            }

            // Check size limit
            if finalData.count > maxAttachmentSize {
                removeAttachmentPlaceholder(localId: localId)
                continue
            }

            // Generate IDs and paths
            let ext = AttachmentPaths.fileExtension(for: "image/jpeg")
            let originalPath = AttachmentPaths.originalPath(idOrUUID: localId, ext: ext)
            let previewPath = AttachmentPaths.previewPath(idOrUUID: localId)

            // Save files
            guard AttachmentPaths.saveData(finalData, to: originalPath) else {
                removeAttachmentPlaceholder(localId: localId)
                continue
            }

            // Generate preview
            var savedPreviewPath: String?
            if let thumbnailData = ImageProcessor.generateThumbnail(from: finalData, mimeType: "image/jpeg") {
                if AttachmentPaths.saveData(thumbnailData, to: previewPath) {
                    savedPreviewPath = previewPath
                }
            }

            // Update placeholder attachment with finalized metadata.
            await MainActor.run {
                guard let attachment = viewModel.attachments.first(where: { $0.id == localId }) else {
                    return
                }

                attachment.byteSize = Int64(finalData.count)
                attachment.localURL = originalPath
                attachment.previewURL = savedPreviewPath

                if let size {
                    attachment.width = Int16(clamping: Int(size.width.rounded()))
                    attachment.height = Int16(clamping: Int(size.height.rounded()))
                }
            }
        }

        selectedPhotoItems = []
    }

    @MainActor
    private func removeAttachmentPlaceholder(localId: String) {
        guard let attachment = viewModel.attachments.first(where: { $0.id == localId }) else { return }
        viewModel.removeAttachment(attachment)
    }
}
