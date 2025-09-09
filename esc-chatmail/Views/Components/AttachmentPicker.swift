import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreData

struct AttachmentPicker: View {
    @Binding var attachments: [Attachment]
    @Environment(\.managedObjectContext) private var viewContext
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isProcessing = false
    
    let maxAttachmentSize: Int64 = 25 * 1024 * 1024 // 25 MB
    
    var body: some View {
        HStack(spacing: 16) {
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
            DocumentPicker(attachments: $attachments)
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
                
                attachments.append(attachment)
            }
        }
        
        selectedPhotoItems = []
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var attachments: [Attachment]
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.managedObjectContext) private var viewContext
    
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
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Task {
                await processDocuments(urls)
            }
            parent.presentationMode.wrappedValue.dismiss()
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
        
        private func processDocuments(_ urls: [URL]) async {
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                
                guard let data = try? Data(contentsOf: url) else { continue }
                
                let filename = url.lastPathComponent
                let mimeType = mimeType(for: url.pathExtension)
                let localId = "local_\(UUID().uuidString)"
                let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
                let originalPath = AttachmentPaths.originalPath(idOrUUID: localId, ext: ext)
                let previewPath = AttachmentPaths.previewPath(idOrUUID: localId)
                
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
                guard AttachmentPaths.saveData(processedData, to: originalPath) else { continue }
                
                // Generate preview
                if let thumbnailData = ImageProcessor.generateThumbnail(from: processedData, mimeType: mimeType) {
                    _ = AttachmentPaths.saveData(thumbnailData, to: previewPath)
                }
                
                // Create attachment entity
                await MainActor.run {
                    let attachment = Attachment(context: parent.viewContext)
                    attachment.setValue(localId, forKey: "id")
                    attachment.setValue(filename, forKey: "filename")
                    attachment.setValue(mimeType, forKey: "mimeType")
                    attachment.setValue(Int64(processedData.count), forKey: "byteSize")
                    attachment.setValue(originalPath, forKey: "localURL")
                    attachment.setValue(previewPath, forKey: "previewURL")
                    attachment.setValue("queued", forKey: "stateRaw")
                    attachment.setValue(width ?? 0, forKey: "width")
                    attachment.setValue(height ?? 0, forKey: "height")
                    attachment.setValue(pageCount ?? 0, forKey: "pageCount")
                    
                    parent.attachments.append(attachment)
                }
            }
        }
        
        private func mimeType(for pathExtension: String) -> String {
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