import SwiftUI
import PhotosUI

/// Message-style input bar with attachment buttons, text field, and send button
struct ComposeInputBar: View {
    @ObservedObject var viewModel: ComposeViewModel
    var focusedField: FocusState<ComposeView.FocusField?>.Binding
    let onSendSuccess: () -> Void

    @Environment(\.managedObjectContext) private var viewContext
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isProcessing = false

    private let maxAttachmentSize: Int64 = 25 * 1024 * 1024 // 25 MB

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
                Button(action: { showPhotoPicker = true }) {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundColor(.blue)
                }
                .disabled(isProcessing)

                Button(action: { showDocumentPicker = true }) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .foregroundColor(.blue)
                }
                .disabled(isProcessing)

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
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 10,
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { oldValue, newValue in
            Task {
                await processPhotoSelections(newValue)
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(attachments: Binding(
                get: { viewModel.attachmentManager.attachments },
                set: { viewModel.attachmentManager.attachments = $0 }
            ))
        }
    }

    private func processPhotoSelections(_ items: [PhotosPickerItem]) async {
        isProcessing = true
        defer { isProcessing = false }

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }

            // Process image
            let (processedData, size) = ImageProcessor.processImage(data: data)
            guard let finalData = processedData else { continue }

            // Check size limit
            if finalData.count > maxAttachmentSize {
                continue // Skip oversized attachments
            }

            // Generate IDs and paths
            let localId = "local_\(UUID().uuidString)"
            let ext = AttachmentPaths.fileExtension(for: "image/jpeg")
            let originalPath = AttachmentPaths.originalPath(idOrUUID: localId, ext: ext)
            let previewPath = AttachmentPaths.previewPath(idOrUUID: localId)

            // Save files
            guard AttachmentPaths.saveData(finalData, to: originalPath) else { continue }

            // Generate preview
            if let thumbnailData = ImageProcessor.generateThumbnail(from: finalData, mimeType: "image/jpeg") {
                _ = AttachmentPaths.saveData(thumbnailData, to: previewPath)
            }

            // Create attachment entity
            await MainActor.run {
                let attachment = Attachment(context: viewContext)
                attachment.setValue(localId, forKey: "id")
                attachment.setValue("photo_\(Date().timeIntervalSince1970).jpg", forKey: "filename")
                attachment.setValue("image/jpeg", forKey: "mimeType")
                attachment.setValue(Int64(finalData.count), forKey: "byteSize")
                attachment.setValue(originalPath, forKey: "localURL")
                attachment.setValue(previewPath, forKey: "previewURL")
                attachment.setValue("queued", forKey: "stateRaw")

                if let size = size {
                    attachment.setValue(Int16(size.width), forKey: "width")
                    attachment.setValue(Int16(size.height), forKey: "height")
                }

                viewModel.addAttachment(attachment)
            }
        }

        selectedPhotoItems = []
    }
}
