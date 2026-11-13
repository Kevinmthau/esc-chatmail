import SwiftUI
import CoreData
import UniformTypeIdentifiers

/// Imports the documents a user picked into a draft's attachments: a queued placeholder per file
/// right away, then the file's bytes (images re-encoded within the size limits, PDFs counted for
/// pages), a thumbnail, and the finished metadata.
///
/// Extracted from `DocumentPicker`'s coordinator so the Mac's `.fileImporter`
/// (`View.documentAttachmentPicker`) imports exactly as iOS's document picker does.
struct DocumentAttachmentImporter {
    /// What the picker offers: PDFs and images.
    static let allowedContentTypes: [UTType] = [
        .pdf,
        .image,
        .jpeg,
        .png,
        .heic
    ]

    let attachments: Binding<[Attachment]>
    let viewContext: NSManagedObjectContext
    let onProcessingChanged: @MainActor (Bool) -> Void
    let onOperationChanged: @MainActor (Task<Void, Never>?) -> Void
    let onImportFailures: @MainActor ([String]) -> Void
    /// The account boundary the import registers with, so sign-out cancels and drains it.
    var registry: AttachmentAccountWorkRegistry = .shared
    /// Whether each file must come with a security scope to be read (`SecurityScope`).
    var securityScope: SecurityScope = .required

    /// What the import asks of a file's security scope before it reads the file.
    enum SecurityScope: Equatable {
        /// The file must open a scope: a picker's files do, and one that does not is not the
        /// user's pick.
        case required
        /// A scope is opened when the file has one, and the file is read either way: a file
        /// dropped on the window. In the Mac's sandbox
        /// `startAccessingSecurityScopedResource()` answers false for a file URL that came
        /// from no picker (measured in the sandboxed test host, 2026-11-12, for one read from
        /// a pasteboard), so requiring it would refuse every drop. A dropped file's permission
        /// to be read is expected to come with the drag. One the app cannot read fails at the
        /// size check, by name.
        case ifOffered

        /// Whether to go on to read a file whose scope did (`true`) or did not open.
        func allowsReading(didStartAccessing: Bool) -> Bool {
            switch self {
            case .required: return didStartAccessing
            case .ifOffered: return true
            }
        }
    }

    /// Starts importing `urls` as an account-scoped operation and reports it through
    /// `onOperationChanged`, so its owner can cancel it.
    @MainActor
    func importDocuments(at urls: [URL]) {
        onProcessingChanged(true)
        // The picker is dismissed as soon as this returns, so the registered
        // operation captures the importer itself (its binding, context and
        // callbacks) until the selected documents finish importing. Account
        // teardown still owns its cancellation and drain through the registry.
        let operation = registry.startDetachedOperation { [self] generation in
            await processDocuments(urls, generation: generation)
            await MainActor.run {
                onProcessingChanged(false)
                onOperationChanged(nil)
            }
        }
        if let operation {
            onOperationChanged(operation)
        } else {
            onProcessingChanged(false)
            onOperationChanged(nil)
        }
    }

    private func processDocuments(
        _ urls: [URL],
        generation: AttachmentAccountWorkGeneration
    ) async {
        var pendingWrites: [String: PickerPendingAttachmentWrite] = [:]
        var failures: [String] = []

        documentLoop: for url in urls {
            guard generation.isActive else { break }
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            // Balanced on every path out of this file's turn, and only when the scope opened.
            defer {
                if didStartAccessing { url.stopAccessingSecurityScopedResource() }
            }
            guard securityScope.allowsReading(didStartAccessing: didStartAccessing) else {
                failures.append(DraftAttachmentImport.ImportError.unreadable(filename: url.lastPathComponent).localizedDescription)
                continue
            }

            let filename = url.lastPathComponent
            var mimeType = mimeType(for: url.pathExtension)
            let localId = "local_\(UUID().uuidString)"
            var ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
            var finalizedFilename = filename
            let previewPath = AttachmentPaths.previewPath(idOrUUID: localId)

            let existingBytes = await MainActor.run {
                DraftAttachmentImport.totalByteCount(attachments.wrappedValue.map(\.byteSize))
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
                let attachment = Attachment(context: viewContext)
                attachment.id = localId
                attachment.filename = filename
                attachment.mimeType = sourceMimeType
                attachment.stateRaw = Attachment.State.queued.rawValue
                attachments.wrappedValue.append(attachment)
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
                guard let attachment = attachments.wrappedValue.first(where: { $0.id == localId }) else {
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
            await onImportFailures(failures)
        }
    }

    private func cleanupPendingWrite(
        _ write: PickerPendingAttachmentWrite?,
        localId: String
    ) async {
        AttachmentPaths.deleteFile(at: write?.originalPath)
        AttachmentPaths.deleteFile(at: write?.previewPath)
        await removeAttachmentPlaceholder(localId: localId)
    }

    @MainActor
    private func removeAttachmentPlaceholder(localId: String) {
        guard let attachment = attachments.wrappedValue.first(where: { $0.id == localId }),
              let index = attachments.wrappedValue.firstIndex(of: attachment) else {
            return
        }

        attachments.wrappedValue.remove(at: index)
        viewContext.delete(attachment)
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
