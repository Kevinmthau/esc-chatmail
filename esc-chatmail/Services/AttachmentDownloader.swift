import Foundation
import CoreData
import Combine

@MainActor
final class AttachmentDownloader: ObservableObject {
    static let shared = AttachmentDownloader()

    @Published var downloadProgress: [String: Double] = [:]
    @Published var activeDownloads: Set<String> = []

    private let apiClient = GmailAPIClient.shared
    private let coreDataStack = CoreDataStack.shared
    private var cancellables = Set<AnyCancellable>()
    private var retryAttempts: [String: Int] = [:]
    private let maxRetryAttempts = 3
    private let baseRetryDelay: TimeInterval = 2.0

    private init() {
        AttachmentPaths.setupDirectories()
    }

    // MARK: - Cleanup

    /// Cleans up tracking data for a completed or cancelled download.
    /// Call this after a download finishes (success or failure) to prevent memory leaks.
    func cleanupDownload(attachmentId: String) {
        downloadProgress.removeValue(forKey: attachmentId)
        activeDownloads.remove(attachmentId)
        retryAttempts.removeValue(forKey: attachmentId)
    }

    /// Cleans up all tracking data. Call on logout to prevent leaking previous user's data.
    func cleanupAll() {
        downloadProgress.removeAll()
        activeDownloads.removeAll()
        retryAttempts.removeAll()
    }
    
    func enqueueAllPendingAttachments() async {
        let context = coreDataStack.newBackgroundContext()

        // Extract needed data inside context.perform to avoid faulting on wrong thread
        let attachmentData: [(objectID: NSManagedObjectID, messageId: String)] = await context.perform {
            let request = NSFetchRequest<Attachment>(entityName: "Attachment")
            request.predicate = NSPredicate(format: "stateRaw == %@", Attachment.State.queued.rawValue)
            request.fetchBatchSize = 10  // Process attachments in small batches to reduce memory usage

            let attachments: [Attachment]
            do {
                attachments = try context.fetch(request)
            } catch {
                Log.warning("Failed to fetch pending attachments", category: .attachment)
                return []
            }

            return attachments.compactMap { attachment in
                guard let message = attachment.message else { return nil }
                return (attachment.objectID, message.id)
            }
        }

        for data in attachmentData {
            await downloadAttachment(attachmentObjectID: data.objectID, messageId: data.messageId, in: context)
        }
    }
    
    func downloadAttachment(attachmentObjectID: NSManagedObjectID, messageId: String, in context: NSManagedObjectContext) async {
        let attachmentId = await context.perform {
            (try? context.existingObject(with: attachmentObjectID) as? Attachment)?.id
        }
        guard let attachmentId = attachmentId else { return }

        // Skip downloading attachments with local IDs - these are from sent messages and don't exist on Gmail
        let didSkipLocal = await context.perform {
            guard let attachmentInContext = try? context.existingObject(with: attachmentObjectID) as? Attachment else {
                return false
            }
            if attachmentInContext.isLocalAttachment {
                Log.debug("Skipping download for local attachment: \(attachmentId)", category: .attachment)
                attachmentInContext.state = .downloaded
                do {
                    try context.save()
                } catch {
                    Log.error("Failed to save local attachment state for \(attachmentId)", category: .attachment, error: error)
                }
                return true
            }
            return false
        }
        if didSkipLocal { return }

        await downloadAttachmentWithRetry(
            attachmentId: attachmentId,
            attachmentObjectID: attachmentObjectID,
            messageId: messageId,
            in: context
        )
    }

    private func downloadAttachmentWithRetry(
        attachmentId: String,
        attachmentObjectID: NSManagedObjectID,
        messageId: String,
        in context: NSManagedObjectContext
    ) async {
        if activeDownloads.contains(attachmentId) {
            Log.debug("Download already in progress for attachment: \(attachmentId)", category: .attachment)
            return
        }

        activeDownloads.insert(attachmentId)
        downloadProgress[attachmentId] = 0.0

        do {
            let attachmentInfo = await context.perform {
                guard let attachmentInContext = try? context.existingObject(with: attachmentObjectID) as? Attachment else {
                    return (mimeType: "application/octet-stream", filename: "")
                }
                return (mimeType: attachmentInContext.mimeType, filename: attachmentInContext.filename)
            }

            // Download attachment data from Gmail with automatic retry
            let data = try await downloadWithRetry(messageId: messageId, attachmentId: attachmentId)

            downloadProgress[attachmentId] = 0.5
            
            // Generate file extension and paths
            // Prefer extension from original filename, fall back to MIME type mapping
            let mimeType = attachmentInfo.mimeType
            let filenameExt = (attachmentInfo.filename as NSString).pathExtension.lowercased()
            let ext = filenameExt.isEmpty ? AttachmentPaths.fileExtension(for: mimeType) : filenameExt
            let originalPath = AttachmentPaths.originalPath(idOrUUID: attachmentId, ext: ext)
            let previewPath = AttachmentPaths.previewPath(idOrUUID: attachmentId)

            // Process heavy work in background to avoid blocking main thread
            let processedResult: (savedOriginal: Bool, width: Int16?, height: Int16?, pageCount: Int16?, savedPreview: Bool) = await Task.detached {
                // Save original file
                let savedOriginal = AttachmentPaths.saveData(data, to: originalPath)

                var width: Int16?
                var height: Int16?
                var pageCount: Int16?
                var savedPreview = false

                if mimeType.starts(with: "image/") {
                    // Process image: get dimensions and create preview
                    if let dimensions = ImageProcessor.getImageDimensions(from: data) {
                        width = Int16(dimensions.width)
                        height = Int16(dimensions.height)
                    }

                    if let thumbnailData = ImageProcessor.generateThumbnail(from: data, mimeType: mimeType) {
                        savedPreview = AttachmentPaths.saveData(thumbnailData, to: previewPath)
                    }
                } else if mimeType == "application/pdf" {
                    // Process PDF: get page count and create preview
                    if let count = ImageProcessor.getPDFPageCount(from: data) {
                        pageCount = Int16(count)
                    }

                    if let thumbnailData = ImageProcessor.generatePDFThumbnail(from: data) {
                        savedPreview = AttachmentPaths.saveData(thumbnailData, to: previewPath)
                    }
                }

                return (savedOriginal, width, height, pageCount, savedPreview)
            }.value

            let saveSucceeded = await context.perform {
                guard let attachmentInContext = try? context.existingObject(with: attachmentObjectID) as? Attachment else {
                    return false
                }

                if processedResult.savedOriginal {
                    attachmentInContext.localURL = originalPath
                } else {
                    Log.warning("Failed to save original attachment file for ID: \(attachmentId)", category: .attachment)
                    attachmentInContext.state = .failed
                }

                if let width = processedResult.width {
                    attachmentInContext.width = width
                }
                if let height = processedResult.height {
                    attachmentInContext.height = height
                }
                if let pageCount = processedResult.pageCount {
                    attachmentInContext.pageCount = pageCount
                }
                if processedResult.savedPreview {
                    attachmentInContext.previewURL = previewPath
                }

                if processedResult.savedOriginal {
                    attachmentInContext.state = .downloaded
                }

                do {
                    try context.save()
                    return true
                } catch {
                    Log.error("Failed to save attachment updates for \(attachmentId)", category: .attachment, error: error)
                    return false
                }
            }

            if !saveSucceeded || !processedResult.savedOriginal {
                activeDownloads.remove(attachmentId)
                downloadProgress.removeValue(forKey: attachmentId)
                return
            }

            downloadProgress[attachmentId] = 1.0
            
            // Clear retry attempts on success
            retryAttempts.removeValue(forKey: attachmentId)

        } catch {
            Log.error("Failed to download attachment \(attachmentId)", category: .attachment, error: error)

            // Rollback any partial download artifacts to prevent orphaned files
            rollbackPartialDownload(attachmentId: attachmentId)

            // Check if we should retry
            let attempts = (retryAttempts[attachmentId] ?? 0) + 1
            retryAttempts[attachmentId] = attempts

            if attempts < maxRetryAttempts {
                // Calculate exponential backoff delay
                let delay = baseRetryDelay * pow(2.0, Double(attempts - 1))
                Log.debug("Retrying attachment \(attachmentId) in \(delay) seconds (attempt \(attempts)/\(maxRetryAttempts))", category: .attachment)

                // Schedule retry
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // Retry the download
                await downloadAttachmentWithRetry(
                    attachmentId: attachmentId,
                    attachmentObjectID: attachmentObjectID,
                    messageId: messageId,
                    in: context
                )
                return
            } else {
                // Max retries reached, mark as permanently failed
                Log.warning("Attachment \(attachmentId) permanently failed after \(maxRetryAttempts) attempts", category: .attachment)
                await context.perform {
                    if let attachmentInContext = try? context.existingObject(with: attachmentObjectID) as? Attachment {
                        attachmentInContext.state = .failed
                        do {
                            try context.save()
                        } catch {
                            Log.error("Failed to save failed attachment state for \(attachmentId)", category: .attachment, error: error)
                        }
                    }
                }
                retryAttempts.removeValue(forKey: attachmentId)
            }
        }

        activeDownloads.remove(attachmentId)
        downloadProgress.removeValue(forKey: attachmentId)
    }
    
    func retryFailedDownload(for attachment: Attachment) async {
        guard let message = attachment.message,
              let attachmentId = attachment.id else { return }
        let attachmentObjectID = attachment.objectID

        // Reset retry counter for manual retry
        retryAttempts.removeValue(forKey: attachmentId)

        let context = coreDataStack.newBackgroundContext()
        let saveSucceeded = await context.perform {
            guard let attachmentInContext = try? context.existingObject(with: attachmentObjectID) as? Attachment else {
                return false
            }
            attachmentInContext.state = .queued
            do {
                try context.save()
                return true
            } catch {
                Log.warning("Failed to save attachment for retry", category: .attachment)
                return false
            }
        }
        if !saveSucceeded { return }
        await downloadAttachment(attachmentObjectID: attachmentObjectID, messageId: message.id, in: context)
    }
    
    func downloadAttachmentIfNeeded(for attachment: Attachment) async {
        // Check if download needed: queued, failed, or file missing from disk
        let needsDownload = attachment.state == .queued ||
                           attachment.state == .failed ||
                           attachment.needsRedownload

        guard needsDownload, let message = attachment.message else { return }

        if attachment.needsRedownload {
            Log.info("Attachment \(attachment.id ?? "unknown") marked as downloaded but file missing - re-downloading", category: .attachment)
        }

        let context = coreDataStack.newBackgroundContext()
        let attachmentObjectID = attachment.objectID
        let shouldProceed = await context.perform {
            guard let attachmentInContext = try? context.existingObject(with: attachmentObjectID) as? Attachment else {
                return false
            }

            if attachmentInContext.state == .downloaded || attachmentInContext.state == .uploaded {
                attachmentInContext.state = .queued
            }

            do {
                try context.save()
                return true
            } catch {
                Log.warning("Failed to save attachment state for download check", category: .attachment)
                return false
            }
        }
        if !shouldProceed { return }
        await downloadAttachment(attachmentObjectID: attachmentObjectID, messageId: message.id, in: context)
    }
    
    private func downloadWithRetry(messageId: String, attachmentId: String) async throws -> Data {
        let executor = RetryExecutor<Data>.network(maxAttempts: 3, baseDelay: 1.0, maxDelay: 10.0)
        return try await executor.execute { [apiClient] in
            try await apiClient.getAttachment(messageId: messageId, attachmentId: attachmentId)
        }
    }

    /// Cleans up any partial download artifacts to prevent orphaned files.
    /// Called when a download fails to ensure clean state for retry.
    private func rollbackPartialDownload(attachmentId: String) {
        // Remove any partial original file (all possible extensions)
        let commonExtensions = ["", "jpg", "jpeg", "png", "gif", "pdf", "doc", "docx", "dat"]
        for ext in commonExtensions {
            let originalPath = AttachmentPaths.originalPath(idOrUUID: attachmentId, ext: ext)
            if let originalURL = AttachmentPaths.fullURL(for: originalPath) {
                FileSystemErrorHandler.removeItem(at: originalURL, category: .attachment)
            }
        }

        // Remove any partial preview file
        let previewPath = AttachmentPaths.previewPath(idOrUUID: attachmentId)
        if let previewURL = AttachmentPaths.fullURL(for: previewPath) {
            FileSystemErrorHandler.removeItem(at: previewURL, category: .attachment)
        }

        // Clear from in-memory cache
        Task {
            await AttachmentCacheActor.shared.removeFromCache(attachmentId)
        }
    }

    /// Cleans up orphaned attachment files that no longer have corresponding Core Data entities.
    /// Runs all operations in background to avoid blocking the main thread.
    func cleanupOrphanedFiles() async {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        // Fetch valid file paths in background context
        let context = coreDataStack.newBackgroundContext()
        let validFiles: Set<String> = await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Attachment")
            request.fetchBatchSize = 50

            let attachments: [NSManagedObject]
            do {
                attachments = try context.fetch(request)
            } catch {
                Log.warning("Failed to fetch attachments for cleanup", category: .attachment)
                return Set<String>()
            }

            return Set(attachments.compactMap { attachment -> [String] in
                guard let att = attachment as? Attachment else { return [] }
                var files: [String] = []
                if let localURL = att.localURL {
                    files.append(localURL)
                }
                if let previewURL = att.previewURL {
                    files.append(previewURL)
                }
                return files
            }.flatMap { $0 })
        }

        guard !validFiles.isEmpty || Task.isCancelled == false else { return }

        // Perform file I/O in detached task to avoid blocking
        await Task.detached {
            // Clean attachments folder
            let attachmentsURL = appSupportURL.appendingPathComponent("Attachments")
            let attachmentContents = FileSystemErrorHandler.contentsOfDirectory(at: attachmentsURL, category: .attachment)
            for fileURL in attachmentContents {
                let relativePath = AttachmentPaths.relativePath(from: fileURL)
                if let path = relativePath, !validFiles.contains(path) {
                    FileSystemErrorHandler.removeItem(at: fileURL, category: .attachment)
                }
            }

            // Clean previews folder
            let previewsURL = appSupportURL.appendingPathComponent("Previews")
            let previewContents = FileSystemErrorHandler.contentsOfDirectory(at: previewsURL, category: .attachment)
            for fileURL in previewContents {
                let relativePath = AttachmentPaths.relativePath(from: fileURL)
                if let path = relativePath, !validFiles.contains(path) {
                    FileSystemErrorHandler.removeItem(at: fileURL, category: .attachment)
                }
            }
        }.value
    }
}
