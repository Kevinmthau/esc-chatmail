import Foundation
import CoreData
import Combine

class AttachmentDownloader: ObservableObject {
    static let shared = AttachmentDownloader()
    
    @Published var downloadProgress: [String: Double] = [:]
    @Published var activeDownloads: Set<String> = []
    
    @MainActor private lazy var apiClient = GmailAPIClient.shared
    private let coreDataStack = CoreDataStack.shared
    private let downloadQueue = DispatchQueue(label: "com.esc.attachment.download", attributes: .concurrent)
    private let semaphore = DispatchSemaphore(value: 2)  // Limit concurrent downloads
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

        guard let attachments = try? context.fetch(request) else { return }
        
        for attachment in attachments {
            if let messageId = attachment.value(forKey: "message") as? Message,
               let messageIdStr = messageId.value(forKey: "id") as? String {
                await downloadAttachment(attachment, messageId: messageIdStr, in: context)
            }
        }
    }
    
    func downloadAttachment(_ attachment: Attachment, messageId: String, in context: NSManagedObjectContext) async {
        guard let attachmentId = attachment.value(forKey: "id") as? String else { return }

        // Skip downloading attachments with local IDs - these are from sent messages and don't exist on Gmail
        if attachmentId.hasPrefix("local_") {
            print("Skipping download for local attachment: \(attachmentId)")
            attachment.setValue("downloaded", forKey: "stateRaw")
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
            let data = try await downloadWithExponentialBackoff(messageId: messageId, attachmentId: attachmentId)
            
            await MainActor.run {
                downloadProgress[attachmentId] = 0.5
            }
            
            // Generate file extension and paths
            let mimeType = attachment.value(forKey: "mimeType") as? String ?? ""
            let ext = AttachmentPaths.fileExtension(for: mimeType)
            let originalPath = AttachmentPaths.originalPath(idOrUUID: attachmentId, ext: ext)
            let previewPath = AttachmentPaths.previewPath(idOrUUID: attachmentId)
            
            // Save original file
            if AttachmentPaths.saveData(data, to: originalPath) {
                attachment.setValue(originalPath, forKey: "localURL")
            } else {
                print("Warning: Failed to save original attachment file for ID: \(attachmentId)")
                // Continue anyway - we can still show preview if it saves
            }
            
            // Process based on type
            if mimeType.starts(with: "image/") {
                // Process image: get dimensions and create preview
                if let dimensions = ImageProcessor.getImageDimensions(from: data) {
                    attachment.setValue(Int16(dimensions.width), forKey: "width")
                    attachment.setValue(Int16(dimensions.height), forKey: "height")
                }
                
                if let thumbnailData = ImageProcessor.generateThumbnail(from: data, mimeType: mimeType) {
                    if AttachmentPaths.saveData(thumbnailData, to: previewPath) {
                        attachment.setValue(previewPath, forKey: "previewURL")
                    }
                }
            } else if mimeType == "application/pdf" {
                // Process PDF: get page count and create preview
                if let pageCount = ImageProcessor.getPDFPageCount(from: data) {
                    attachment.setValue(Int16(pageCount), forKey: "pageCount")
                }
                
                if let thumbnailData = ImageProcessor.generatePDFThumbnail(from: data) {
                    if AttachmentPaths.saveData(thumbnailData, to: previewPath) {
                        attachment.setValue(previewPath, forKey: "previewURL")
                    }
                }
            }
            
            // Update state to downloaded
            attachment.setValue("downloaded", forKey: "stateRaw")
            
            await MainActor.run {
                downloadProgress[attachmentId] = 1.0
            }
            
            // Save context
            coreDataStack.saveIfNeeded(context: context)
            
            // Clear retry attempts on success
            retryAttempts.removeValue(forKey: attachmentId)

        } catch {
            print("Failed to download attachment \(attachmentId): \(error)")

            // Check if we should retry
            let attempts = (retryAttempts[attachmentId] ?? 0) + 1
            retryAttempts[attachmentId] = attempts

            if attempts < maxRetryAttempts {
                // Calculate exponential backoff delay
                let delay = baseRetryDelay * pow(2.0, Double(attempts - 1))
                print("Retrying attachment \(attachmentId) in \(delay) seconds (attempt \(attempts)/\(maxRetryAttempts))")

                // Schedule retry
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // Retry the download
                await downloadAttachmentWithRetry(attachment, messageId: messageId, attachmentId: attachmentId, in: context)
                return
            } else {
                // Max retries reached, mark as permanently failed
                print("Attachment \(attachmentId) permanently failed after \(maxRetryAttempts) attempts")
                attachment.setValue("failed", forKey: "stateRaw")
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
        guard let message = attachment.value(forKey: "message") as? Message,
              let messageId = message.value(forKey: "id") as? String,
              let attachmentId = attachment.value(forKey: "id") as? String else { return }

        // Reset retry counter for manual retry
        retryAttempts.removeValue(forKey: attachmentId)

        let context = coreDataStack.newBackgroundContext()
        guard let attachmentInContext = try? context.existingObject(with: attachment.objectID) as? Attachment else { return }

        attachmentInContext.setValue("queued", forKey: "stateRaw")
        coreDataStack.saveIfNeeded(context: context)

        await downloadAttachment(attachmentInContext, messageId: messageId, in: context)
    }
    
    func downloadAttachmentIfNeeded(for attachment: Attachment) async {
        let stateRaw = attachment.value(forKey: "stateRaw") as? String ?? ""
        guard stateRaw == "queued" || stateRaw == "failed",
              let message = attachment.value(forKey: "message") as? Message,
              let messageId = message.value(forKey: "id") as? String else { return }
        
        let context = coreDataStack.newBackgroundContext()
        guard let attachmentInContext = try? context.existingObject(with: attachment.objectID) as? Attachment else { return }
        
        await downloadAttachment(attachmentInContext, messageId: messageId, in: context)
    }
    
    private func downloadWithExponentialBackoff(messageId: String, attachmentId: String) async throws -> Data {
        var lastError: Error?
        let maxAttempts = 3
        var retryDelay: TimeInterval = 1.0

        for attempt in 0..<maxAttempts {
            do {
                return try await apiClient.getAttachment(messageId: messageId, attachmentId: attachmentId)
            } catch {
                lastError = error

                // Check if error is retryable
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .dnsLookupFailed:
                        if attempt < maxAttempts - 1 {
                            print("Network error downloading attachment, retrying in \(retryDelay) seconds...")
                            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                            retryDelay = min(retryDelay * 2, 10.0) // Exponential backoff capped at 10 seconds
                            continue
                        }
                    default:
                        throw error
                    }
                }

                // For non-network errors, throw immediately
                if attempt == maxAttempts - 1 {
                    throw lastError ?? error
                }
            }
        }

        throw lastError ?? URLError(.unknown)
    }

    func cleanupOrphanedFiles() {
        let fileManager = FileManager.default
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        
        let context = coreDataStack.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "Attachment")
        request.fetchBatchSize = 50  // Process in batches for better memory usage

        guard let attachments = try? context.fetch(request) else { return }
        
        let validFiles = Set(attachments.compactMap { attachment -> [String] in
            var files: [String] = []
            if let localURL = attachment.value(forKey: "localURL") as? String {
                files.append(localURL)
            }
            if let previewURL = attachment.value(forKey: "previewURL") as? String {
                files.append(previewURL)
            }
            return files
        }.flatMap { $0 })
        
        // Clean attachments folder
        let attachmentsURL = appSupportURL.appendingPathComponent("Attachments")
        if let contents = try? fileManager.contentsOfDirectory(at: attachmentsURL, includingPropertiesForKeys: nil) {
            for fileURL in contents {
                let relativePath = AttachmentPaths.relativePath(from: fileURL)
                if let path = relativePath, !validFiles.contains(path) {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        }
        
        // Clean previews folder
        let previewsURL = appSupportURL.appendingPathComponent("Previews")
        if let contents = try? fileManager.contentsOfDirectory(at: previewsURL, includingPropertiesForKeys: nil) {
            for fileURL in contents {
                let relativePath = AttachmentPaths.relativePath(from: fileURL)
                if let path = relativePath, !validFiles.contains(path) {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        }
    }
}