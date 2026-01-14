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
    
    func enqueueAllPendingAttachments() async {
        let context = coreDataStack.newBackgroundContext()
        let request = NSFetchRequest<Attachment>(entityName: "Attachment")
        request.predicate = NSPredicate(format: "stateRaw == %@", "queued")
        request.fetchBatchSize = 10  // Process attachments in small batches to reduce memory usage

        let attachments: [Attachment]
        do {
            attachments = try context.fetch(request)
        } catch {
            Log.warning("Failed to fetch pending attachments", category: .attachment)
            return
        }
        
        for attachment in attachments {
            if let message = attachment.message {
                await downloadAttachment(attachment, messageId: message.id, in: context)
            }
        }
    }
    
    func downloadAttachment(_ attachment: Attachment, messageId: String, in context: NSManagedObjectContext) async {
        guard let attachmentId = attachment.id else { return }

        // Skip downloading attachments with local IDs - these are from sent messages and don't exist on Gmail
        if attachment.isLocalAttachment {
            Log.debug("Skipping download for local attachment: \(attachmentId)", category: .attachment)
            attachment.state = .downloaded
            coreDataStack.saveIfNeeded(context: context)
            return
        }

        await downloadAttachmentWithRetry(attachment, messageId: messageId, attachmentId: attachmentId, in: context)
    }

    private func downloadAttachmentWithRetry(_ attachment: Attachment, messageId: String, attachmentId: String, in context: NSManagedObjectContext) async {
        await MainActor.run {
            activeDownloads.insert(attachmentId)
            downloadProgress[attachmentId] = 0.0
        }

        do {
            // Download attachment data from Gmail with automatic retry
            let data = try await downloadWithRetry(messageId: messageId, attachmentId: attachmentId)
            
            await MainActor.run {
                downloadProgress[attachmentId] = 0.5
            }
            
            // Generate file extension and paths
            let mimeType = attachment.mimeType
            let ext = AttachmentPaths.fileExtension(for: mimeType)
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

            // Update Core Data properties on MainActor
            if processedResult.savedOriginal {
                attachment.localURL = originalPath
            } else {
                Log.warning("Failed to save original attachment file for ID: \(attachmentId)", category: .attachment)
            }

            if let width = processedResult.width {
                attachment.width = width
            }
            if let height = processedResult.height {
                attachment.height = height
            }
            if let pageCount = processedResult.pageCount {
                attachment.pageCount = pageCount
            }
            if processedResult.savedPreview {
                attachment.previewURL = previewPath
            }

            // Update state to downloaded
            attachment.state = .downloaded
            
            await MainActor.run {
                downloadProgress[attachmentId] = 1.0
            }
            
            // Save context
            coreDataStack.saveIfNeeded(context: context)
            
            // Clear retry attempts on success
            retryAttempts.removeValue(forKey: attachmentId)

        } catch {
            Log.error("Failed to download attachment \(attachmentId)", category: .attachment, error: error)

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
                await downloadAttachmentWithRetry(attachment, messageId: messageId, attachmentId: attachmentId, in: context)
                return
            } else {
                // Max retries reached, mark as permanently failed
                Log.warning("Attachment \(attachmentId) permanently failed after \(maxRetryAttempts) attempts", category: .attachment)
                attachment.state = .failed
                coreDataStack.saveIfNeeded(context: context)
                retryAttempts.removeValue(forKey: attachmentId)
            }
        }
        
        await MainActor.run {
            activeDownloads.remove(attachmentId)
            downloadProgress.removeValue(forKey: attachmentId)
        }
    }
    
    func retryFailedDownload(for attachment: Attachment) async {
        guard let message = attachment.message,
              let attachmentId = attachment.id else { return }

        // Reset retry counter for manual retry
        retryAttempts.removeValue(forKey: attachmentId)

        let context = coreDataStack.newBackgroundContext()
        let attachmentInContext: Attachment
        do {
            guard let att = try context.existingObject(with: attachment.objectID) as? Attachment else { return }
            attachmentInContext = att
        } catch {
            Log.warning("Failed to fetch attachment for retry", category: .attachment)
            return
        }

        attachmentInContext.state = .queued
        coreDataStack.saveIfNeeded(context: context)

        await downloadAttachment(attachmentInContext, messageId: message.id, in: context)
    }
    
    func downloadAttachmentIfNeeded(for attachment: Attachment) async {
        guard attachment.state == .queued || attachment.state == .failed,
              let message = attachment.message else { return }

        let context = coreDataStack.newBackgroundContext()
        let attachmentInContext: Attachment
        do {
            guard let att = try context.existingObject(with: attachment.objectID) as? Attachment else { return }
            attachmentInContext = att
        } catch {
            Log.warning("Failed to fetch attachment for download check", category: .attachment)
            return
        }

        await downloadAttachment(attachmentInContext, messageId: message.id, in: context)
    }
    
    private func downloadWithRetry(messageId: String, attachmentId: String) async throws -> Data {
        let executor = RetryExecutor<Data>.network(maxAttempts: 3, baseDelay: 1.0, maxDelay: 10.0)
        return try await executor.execute { [apiClient] in
            try await apiClient.getAttachment(messageId: messageId, attachmentId: attachmentId)
        }
    }

    func cleanupOrphanedFiles() {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let context = coreDataStack.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "Attachment")
        request.fetchBatchSize = 50  // Process in batches for better memory usage

        let attachments: [NSManagedObject]
        do {
            attachments = try context.fetch(request)
        } catch {
            Log.warning("Failed to fetch attachments for cleanup", category: .attachment)
            return
        }

        let validFiles = Set(attachments.compactMap { attachment -> [String] in
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
    }
}