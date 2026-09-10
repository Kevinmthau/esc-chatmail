import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreData

private struct PickerPendingAttachmentWrite {
    var originalPath: String?
    var previewPath: String?
}

enum AttachmentImportFinalizationResult: Equatable {
    case finalized
    case placeholderRemoved
    case cancelled

    static func resolve(didFinalize: Bool, generationIsActive: Bool) -> Self {
        if didFinalize {
            return .finalized
        }
        return generationIsActive ? .placeholderRemoved : .cancelled
    }
}

struct AttachmentPicker: View {
    @Binding var attachments: [Attachment]
    @Binding var isProcessing: Bool
    @Environment(\.managedObjectContext) private var viewContext
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var photoProcessingTask: Task<Void, Never>?
    @State private var documentProcessingTask: Task<Void, Never>?
    @State private var photoProcessingID: UUID?

    private let maxAttachmentSize: Int64 = 25 * 1024 * 1024 // 25 MB
    
    var body: some View {
        HStack(spacing: 16) {
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
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 10,
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { oldValue, newValue in
            guard !newValue.isEmpty else { return }
            photoProcessingTask?.cancel()
            let processingID = UUID()
            let attachmentSizeLimit = maxAttachmentSize
            photoProcessingID = processingID
            isProcessing = true
            // Image decoding, resizing, thumbnailing, and file writes must not
            // occupy MainActor while the user continues typing a reply.
            photoProcessingTask = AttachmentAccountWorkRegistry.shared.startDetachedOperation { generation in
                await processPhotoSelections(
                    newValue,
                    generation: generation,
                    maxAttachmentSize: attachmentSizeLimit
                )
                await finishPhotoProcessing(processingID: processingID)
            }
            if photoProcessingTask == nil {
                finishPhotoProcessing(processingID: processingID)
            }
        }
        .onDisappear {
            photoProcessingTask?.cancel()
            documentProcessingTask?.cancel()
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(
                attachments: $attachments,
                onProcessingChanged: { isProcessing = $0 },
                onOperationChanged: { documentProcessingTask = $0 }
            )
        }
    }
    
    private nonisolated func processPhotoSelections(
        _ items: [PhotosPickerItem],
        generation: AttachmentAccountWorkGeneration,
        maxAttachmentSize: Int64
    ) async {
        guard generation.isActive else { return }
        var pendingWrites: [String: PickerPendingAttachmentWrite] = [:]
        
        for item in items {
            guard generation.isActive else { break }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            guard generation.isActive else { break }
            
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
            pendingWrites[localId] = PickerPendingAttachmentWrite(
                originalPath: originalPath,
                previewPath: nil
            )
            
            // Save files
            guard generation.isActive else { break }
            guard AttachmentPaths.saveData(finalData, to: originalPath) else {
                AttachmentPaths.deleteFile(at: originalPath)
                pendingWrites.removeValue(forKey: localId)
                continue
            }
            
            // Generate preview
            var savedPreviewPath: String?
            if let thumbnailData = ImageProcessor.generateThumbnail(from: finalData, mimeType: "image/jpeg") {
                pendingWrites[localId]?.previewPath = previewPath
                if AttachmentPaths.saveData(thumbnailData, to: previewPath) {
                    savedPreviewPath = previewPath
                } else {
                    AttachmentPaths.deleteFile(at: previewPath)
                    pendingWrites[localId]?.previewPath = nil
                }
            }
            
            // Create attachment entity
            let finalizedPreviewPath = savedPreviewPath
            let didAppend = await MainActor.run { () -> Bool in
                guard generation.isActive else { return false }
                let attachment = Attachment(context: viewContext)
                attachment.setValue(localId, forKey: "id")
                attachment.setValue("photo_\(Date().timeIntervalSince1970).jpg", forKey: "filename")
                attachment.setValue("image/jpeg", forKey: "mimeType")
                attachment.setValue(Int64(finalData.count), forKey: "byteSize")
                attachment.setValue(originalPath, forKey: "localURL")
                attachment.setValue(finalizedPreviewPath, forKey: "previewURL")
                attachment.setValue("queued", forKey: "stateRaw")
                
                if let size = size {
                    attachment.setValue(Int16(size.width), forKey: "width")
                    attachment.setValue(Int16(size.height), forKey: "height")
                }
                
                attachments.append(attachment)
                return true
            }
            if didAppend {
                pendingWrites.removeValue(forKey: localId)
            } else {
                break
            }
        }

        for write in pendingWrites.values {
            AttachmentPaths.deleteFile(at: write.originalPath)
            AttachmentPaths.deleteFile(at: write.previewPath)
        }
        
        if generation.isActive {
            await MainActor.run {
                selectedPhotoItems = []
            }
        }
    }

    @MainActor
    private func finishPhotoProcessing(processingID: UUID) {
        guard photoProcessingID == processingID else { return }
        photoProcessingID = nil
        photoProcessingTask = nil
        isProcessing = false
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var attachments: [Attachment]
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.managedObjectContext) private var viewContext
    let onProcessingChanged: @MainActor (Bool) -> Void
    let onOperationChanged: @MainActor (Task<Void, Never>?) -> Void

    init(
        attachments: Binding<[Attachment]>,
        onProcessingChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        onOperationChanged: @escaping @MainActor (Task<Void, Never>?) -> Void = { _ in }
    ) {
        self._attachments = attachments
        self.onProcessingChanged = onProcessingChanged
        self.onOperationChanged = onOperationChanged
    }
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            .pdf,
            .image,
            .jpeg,
            .png,
            .heic
        ])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    @MainActor
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onProcessingChanged(true)
            // The representable is dismissed immediately below, so the
            // registered operation must retain its coordinator until selected
            // documents finish importing. Account teardown still owns its
            // cancellation and drain through the registry.
            let operation = AttachmentAccountWorkRegistry.shared.startDetachedOperation { [self] generation in
                await processDocuments(urls, generation: generation)
                await MainActor.run {
                    parent.onProcessingChanged(false)
                    parent.onOperationChanged(nil)
                }
            }
            if let operation {
                parent.onOperationChanged(operation)
            } else {
                parent.onProcessingChanged(false)
                parent.onOperationChanged(nil)
            }
            parent.presentationMode.wrappedValue.dismiss()
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
        
        private nonisolated func processDocuments(
            _ urls: [URL],
            generation: AttachmentAccountWorkGeneration
        ) async {
            var pendingWrites: [String: PickerPendingAttachmentWrite] = [:]

            documentLoop: for url in urls {
                guard generation.isActive else { break }
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }

                let filename = url.lastPathComponent
                let mimeType = mimeType(for: url.pathExtension)
                let localId = "local_\(UUID().uuidString)"
                let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
                let originalPath = AttachmentPaths.originalPath(idOrUUID: localId, ext: ext)
                let previewPath = AttachmentPaths.previewPath(idOrUUID: localId)

                // Add placeholder immediately so all selected files appear right away.
                let didAddPlaceholder = await MainActor.run { () -> Bool in
                    guard generation.isActive else { return false }
                    let attachment = Attachment(context: parent.viewContext)
                    attachment.id = localId
                    attachment.filename = filename
                    attachment.mimeType = mimeType
                    attachment.stateRaw = Attachment.State.queued.rawValue
                    parent.attachments.append(attachment)
                    return true
                }
                guard didAddPlaceholder else { break }
                pendingWrites[localId] = PickerPendingAttachmentWrite()

                guard let data = try? Data(contentsOf: url) else {
                    await cleanupPendingWrite(
                        pendingWrites.removeValue(forKey: localId),
                        localId: localId
                    )
                    continue
                }
                guard generation.isActive else { break }

                // Process based on type
                var processedData = data
                var width: Int16? = nil
                var height: Int16? = nil
                var pageCount: Int16? = nil
                
                if mimeType.starts(with: "image/") {
                    // Process image
                    let (processed, size) = ImageProcessor.processImage(data: data)
                    if let processed = processed {
                        processedData = processed
                        if let size = size {
                            width = Int16(size.width)
                            height = Int16(size.height)
                        }
                    }
                } else if mimeType == "application/pdf" {
                    // Get PDF info
                    if let count = ImageProcessor.getPDFPageCount(from: data) {
                        pageCount = Int16(count)
                    }
                }

                // Save files
                pendingWrites[localId]?.originalPath = originalPath
                guard generation.isActive else { break }
                guard AttachmentPaths.saveData(processedData, to: originalPath) else {
                    await cleanupPendingWrite(
                        pendingWrites.removeValue(forKey: localId),
                        localId: localId
                    )
                    continue
                }

                // Generate preview
                var savedPreviewPath: String?
                if let thumbnailData = ImageProcessor.generateThumbnail(from: processedData, mimeType: mimeType) {
                    pendingWrites[localId]?.previewPath = previewPath
                    if AttachmentPaths.saveData(thumbnailData, to: previewPath) {
                        savedPreviewPath = previewPath
                    } else {
                        AttachmentPaths.deleteFile(at: previewPath)
                        pendingWrites[localId]?.previewPath = nil
                    }
                }

                // Fill in finalized metadata for the placeholder attachment.
                let finalizedByteSize = Int64(processedData.count)
                let finalizedPreviewPath = savedPreviewPath
                let finalizedWidth = width ?? 0
                let finalizedHeight = height ?? 0
                let finalizedPageCount = pageCount ?? 0
                let didFinalize = await MainActor.run { () -> Bool in
                    guard generation.isActive else { return false }
                    guard let attachment = parent.attachments.first(where: { $0.id == localId }) else {
                        return false
                    }

                    attachment.byteSize = finalizedByteSize
                    attachment.localURL = originalPath
                    attachment.previewURL = finalizedPreviewPath
                    attachment.width = finalizedWidth
                    attachment.height = finalizedHeight
                    attachment.pageCount = finalizedPageCount
                    return true
                }
                switch AttachmentImportFinalizationResult.resolve(
                    didFinalize: didFinalize,
                    generationIsActive: generation.isActive
                ) {
                case .finalized:
                    pendingWrites.removeValue(forKey: localId)
                case .placeholderRemoved:
                    await cleanupPendingWrite(
                        pendingWrites.removeValue(forKey: localId),
                        localId: localId
                    )
                    continue documentLoop
                case .cancelled:
                    break documentLoop
                }
            }

            for (localId, write) in pendingWrites {
                await cleanupPendingWrite(write, localId: localId)
            }
        }

        private nonisolated func cleanupPendingWrite(
            _ write: PickerPendingAttachmentWrite?,
            localId: String
        ) async {
            AttachmentPaths.deleteFile(at: write?.originalPath)
            AttachmentPaths.deleteFile(at: write?.previewPath)
            await removeAttachmentPlaceholder(localId: localId)
        }

        @MainActor
        private func removeAttachmentPlaceholder(localId: String) {
            guard let attachment = parent.attachments.first(where: { $0.id == localId }),
                  let index = parent.attachments.firstIndex(of: attachment) else {
                return
            }

            parent.attachments.remove(at: index)
            parent.viewContext.delete(attachment)
        }

        private nonisolated func mimeType(for pathExtension: String) -> String {
            switch pathExtension.lowercased() {
            case "pdf": return "application/pdf"
            case "jpg", "jpeg": return "image/jpeg"
            case "png": return "image/png"
            case "heic", "heif": return "image/heic"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            default: return "application/octet-stream"
            }
        }
    }
}
