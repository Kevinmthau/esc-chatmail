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

    @State private var importErrorMessage: String?
    
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
            photoProcessingID = processingID
            isProcessing = true
            // Image decoding, resizing, thumbnailing, and file writes must not
            // occupy MainActor while the user continues typing a reply.
            photoProcessingTask = AttachmentAccountWorkRegistry.shared.startDetachedOperation { generation in
                await processPhotoSelections(
                    newValue,
                    generation: generation
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
                onOperationChanged: { documentProcessingTask = $0 },
                onImportFailures: { importErrorMessage = DraftAttachmentImport.failureMessage($0) }
            )
        }
        .alert("Some Attachments Weren’t Added", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
    }
    
    private nonisolated func processPhotoSelections(
        _ items: [PhotosPickerItem],
        generation: AttachmentAccountWorkGeneration
    ) async {
        guard generation.isActive else { return }
        var pendingWrites: [String: PickerPendingAttachmentWrite] = [:]
        var failures: [String] = []
        
        for (index, item) in items.enumerated() {
            guard generation.isActive else { break }
            let filename = "Photo \(index + 1)"
            let prepared: DraftAttachmentImport.PreparedImage
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw DraftAttachmentImport.ImportError.unreadable(filename: filename)
                }
                guard generation.isActive else { break }
                let existingBytes = await MainActor.run {
                    DraftAttachmentImport.totalByteCount(attachments.map(\.byteSize))
                }
                prepared = try DraftAttachmentImport.prepareImage(
                    data: data, filename: filename, existingByteCount: existingBytes
                )
            } catch {
                if generation.isActive { failures.append("\(filename): \(error.localizedDescription)") }
                continue
            }
            let finalData = prepared.data
            let localId = "local_\(UUID().uuidString)"
            let originalPath = AttachmentPaths.originalPath(idOrUUID: localId, ext: prepared.fileExtension)
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
                failures.append(DraftAttachmentImport.ImportError.cannotSave(filename: filename).localizedDescription)
                continue
            }
            
            // Generate preview
            var savedPreviewPath: String?
            if let thumbnailData = ImageProcessor.generateThumbnail(from: finalData, mimeType: prepared.mimeType) {
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
                attachment.setValue(prepared.filename(replacingExtensionOf: "photo_\(Int(Date().timeIntervalSince1970))_\(index)"), forKey: "filename")
                attachment.setValue(prepared.mimeType, forKey: "mimeType")
                attachment.setValue(Int64(finalData.count), forKey: "byteSize")
                attachment.setValue(originalPath, forKey: "localURL")
                attachment.setValue(finalizedPreviewPath, forKey: "previewURL")
                attachment.setValue("queued", forKey: "stateRaw")
                
                attachment.width = Int16(clamping: Int(prepared.size.width.rounded()))
                attachment.height = Int16(clamping: Int(prepared.size.height.rounded()))
                
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
            let errorMessage = DraftAttachmentImport.failureMessage(failures)
            await MainActor.run {
                selectedPhotoItems = []
                importErrorMessage = errorMessage
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
    let onImportFailures: @MainActor ([String]) -> Void

    init(
        attachments: Binding<[Attachment]>,
        onProcessingChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        onOperationChanged: @escaping @MainActor (Task<Void, Never>?) -> Void = { _ in },
        onImportFailures: @escaping @MainActor ([String]) -> Void = { _ in }
    ) {
        self._attachments = attachments
        self.onProcessingChanged = onProcessingChanged
        self.onOperationChanged = onOperationChanged
        self.onImportFailures = onImportFailures
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
            var failures: [String] = []

            documentLoop: for url in urls {
                guard generation.isActive else { break }
                guard url.startAccessingSecurityScopedResource() else {
                    failures.append(DraftAttachmentImport.ImportError.unreadable(filename: url.lastPathComponent).localizedDescription)
                    continue
                }
                defer { url.stopAccessingSecurityScopedResource() }

                let filename = url.lastPathComponent
                var mimeType = mimeType(for: url.pathExtension)
                let localId = "local_\(UUID().uuidString)"
                var ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
                var finalizedFilename = filename
                let previewPath = AttachmentPaths.previewPath(idOrUUID: localId)

                let existingBytes = await MainActor.run {
                    DraftAttachmentImport.totalByteCount(parent.attachments.map(\.byteSize))
                }
                do {
                    try DraftAttachmentImport.preflightDocument(at: url, existingByteCount: existingBytes)
                } catch {
                    failures.append("\(filename): \(error.localizedDescription)")
                    continue
                }

                // Add placeholder immediately so all selected files appear right away.
                let sourceMimeType = mimeType
                let didAddPlaceholder = await MainActor.run { () -> Bool in
                    guard generation.isActive else { return false }
                    let attachment = Attachment(context: parent.viewContext)
                    attachment.id = localId
                    attachment.filename = filename
                    attachment.mimeType = sourceMimeType
                    attachment.stateRaw = Attachment.State.queued.rawValue
                    parent.attachments.append(attachment)
                    return true
                }
                guard didAddPlaceholder else { break }
                pendingWrites[localId] = PickerPendingAttachmentWrite()

                guard let data = try? Data(contentsOf: url) else {
                    failures.append(DraftAttachmentImport.ImportError.unreadable(filename: filename).localizedDescription)
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
                
                do {
                    // Recheck after reading in case a provider changed the file.
                    try DraftAttachmentImport.validateSize(
                        byteCount: Int64(data.count), existingByteCount: existingBytes, filename: filename
                    )
                    if mimeType.starts(with: "image/") {
                        let prepared = try DraftAttachmentImport.prepareImage(
                            data: data, filename: filename, existingByteCount: existingBytes
                        )
                        processedData = prepared.data
                        mimeType = prepared.mimeType
                        ext = prepared.fileExtension
                        finalizedFilename = prepared.filename(replacingExtensionOf: filename)
                        width = Int16(clamping: Int(prepared.size.width.rounded()))
                        height = Int16(clamping: Int(prepared.size.height.rounded()))
                    } else if mimeType == "application/pdf",
                              let count = ImageProcessor.getPDFPageCount(from: data) {
                        pageCount = Int16(clamping: count)
                    }
                } catch {
                    failures.append("\(filename): \(error.localizedDescription)")
                    await cleanupPendingWrite(pendingWrites.removeValue(forKey: localId), localId: localId)
                    continue
                }
                let originalPath = AttachmentPaths.originalPath(idOrUUID: localId, ext: ext)

                // Save files
                pendingWrites[localId]?.originalPath = originalPath
                guard generation.isActive else { break }
                guard AttachmentPaths.saveData(processedData, to: originalPath) else {
                    failures.append(DraftAttachmentImport.ImportError.cannotSave(filename: filename).localizedDescription)
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
                let finalFilename = finalizedFilename
                let finalMimeType = mimeType
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

                    attachment.filename = finalFilename
                    attachment.mimeType = finalMimeType
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
            if generation.isActive, !failures.isEmpty {
                await parent.onImportFailures(failures)
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
