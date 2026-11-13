import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreData

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
    /// How the two pickers are offered: two buttons (the iPhone's reply bar), or one "+" menu
    /// (the Mac's composer). What a picker returns is handled the same either way.
    var style: AttachmentPickerStyle = .inlineButtons
    /// Files dropped on the chat, for this picker to import (`DraftFileDrop`). The picker takes
    /// each request once and clears it as it starts on it. Nothing sets one on iOS.
    var fileDrop: Binding<DraftFileDrop?> = .constant(nil)
    @Environment(\.managedObjectContext) private var viewContext
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var photoProcessingTask: Task<Void, Never>?
    @State private var documentProcessingTask: Task<Void, Never>?
    @State private var photoProcessingID: UUID?

    @State private var importErrorMessage: String?
    
    var body: some View {
        controls
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
        .documentAttachmentPicker(
            isPresented: $showDocumentPicker,
            attachments: $attachments,
            onProcessingChanged: { isProcessing = $0 },
            onOperationChanged: { documentProcessingTask = $0 },
            onImportFailures: { importErrorMessage = DraftAttachmentImport.failureMessage($0) }
        )
        // A drop is imported when it arrives, or, where an import is running then, when that
        // one ends (`importPendingFileDropIfIdle`). `initial`, for a drop that was taken
        // while no picker was on screen to hear of it.
        .onChange(of: fileDrop.wrappedValue, initial: true) { _, _ in
            importPendingFileDropIfIdle()
        }
        .onChange(of: isProcessing) { _, _ in
            importPendingFileDropIfIdle()
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
    
    /// Starts on the composer's pending drop unless an import is running
    /// (`DraftFileDropPolicy.startsImport`), and is asked again when that import ends.
    ///
    /// A drop is decided before it gets here (`DraftFileDropPolicy.decision`), and refused
    /// during an import, so one already running is not expected. It is still checked: two
    /// imports share `isProcessing`, and the first to end would turn it off under the other.
    /// The drop is left where it is then, not cleared. The chat told AppKit the drop was
    /// taken, so the files did not slide back, and clearing it here attached nothing and said
    /// nothing.
    private func importPendingFileDropIfIdle() {
        guard DraftFileDropPolicy.startsImport(
            hasPendingDrop: fileDrop.wrappedValue != nil,
            isProcessingAttachments: isProcessing
        ), let drop = fileDrop.wrappedValue else { return }
        fileDrop.wrappedValue = nil
        importDroppedFiles(drop)
    }

    /// Imports the files of a drop as the Files picker imports its own, and names the files
    /// the drop could not take in the alert the import's failures use.
    private func importDroppedFiles(_ drop: DraftFileDrop) {
        let unsupported = DraftFileDropPolicy.failures(forUnsupportedFilenames: drop.unsupportedFilenames)
        if let message = DraftAttachmentImport.failureMessage(unsupported) {
            importErrorMessage = message
        }
        guard !drop.fileURLs.isEmpty else { return }
        DocumentAttachmentImporter(
            attachments: $attachments,
            viewContext: viewContext,
            onProcessingChanged: { isProcessing = $0 },
            onOperationChanged: { documentProcessingTask = $0 },
            onImportFailures: { failures in
                // Added to the lines still on screen, so the alert for this drop's
                // unsupported files is not replaced by the one for its failed imports.
                let shown = importErrorMessage.map { [$0] } ?? []
                importErrorMessage = DraftAttachmentImport.failureMessage(shown + failures)
            },
            securityScope: .ifOffered
        )
        .importDocuments(at: drop.fileURLs)
    }

    @ViewBuilder
    private var controls: some View {
        switch style {
        case .inlineButtons:
            inlineButtons
        case .plusMenu(let diameter):
            #if os(macOS)
            MacAttachmentMenuButton(
                diameter: diameter,
                onChoosePhotos: { showPhotoPicker = true },
                onChooseFiles: { showDocumentPicker = true }
            )
            .disabled(isProcessing)
            #else
            let _ = diameter
            inlineButtons
            #endif
        }
    }

    private var inlineButtons: some View {
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
