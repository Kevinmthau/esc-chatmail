import Foundation
import CoreData
import Combine

private final class AttachmentDownloadGenerationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Recovers the received-message body parts represented by synthesized
/// `local_inline_*` attachment rows.
///
/// Older app versions stored these parts under attachment-ID-only filenames.
/// The deterministic ID can repeat in separate messages, so those legacy bytes
/// are not evidence that they belong to the requested message. Recovery always
/// fetches that message's authoritative full MIME payload, recomputes the
/// synthesized ID, and only then writes message-scoped storage.
enum SynthesizedInlineAttachmentRecovery {
    private struct Candidate: @unchecked Sendable {
        let objectID: NSManagedObjectID
        let attachmentId: String
        let payload: AttachmentPaths.SynthesizedInlinePayload
    }

    private struct PersistenceResult: @unchecked Sendable {
        let objectID: NSManagedObjectID
        let attachmentId: String
        let originalPath: String
        let previewPath: String?
        let width: Int16?
        let height: Int16?
        let pageCount: Int16?
        let savedOriginal: Bool
    }

    static func persistedImageDimension(_ dimension: CGFloat) -> Int16 {
        guard dimension.isFinite else { return 0 }
        return Int16(clamping: Int(dimension.rounded()))
    }

    static func persistedPDFPageCount(_ pageCount: Int) -> Int16 {
        Int16(clamping: pageCount)
    }

    static func recover(
        messageId: String,
        requestedAttachmentObjectID: NSManagedObjectID,
        requestedAttachmentId: String,
        apiClient: any GmailAPIClientProtocol,
        makeBackgroundContext: @escaping @Sendable () -> NSManagedObjectContext,
        isActive: @escaping @Sendable () -> Bool = { !Task.isCancelled }
    ) async -> Data? {
        guard requestedAttachmentId.hasPrefix("local_inline_"), isActive() else {
            return nil
        }

        do {
            let gmailMessage = try await apiClient.getMessage(
                id: messageId,
                format: "full"
            )
            guard isActive(), gmailMessage.id == messageId else {
                return nil
            }

            let recoveredPayloads = AttachmentPaths.synthesizedInlinePayloads(
                in: gmailMessage
            )
            let requestedPayload = recoveredPayloads[requestedAttachmentId]
            guard isActive() else { return nil }

            let lookupContext = makeBackgroundContext()
            let candidates: [Candidate]? = await lookupContext.perform {
                guard let requestedAttachment = try? lookupContext.existingObject(
                    with: requestedAttachmentObjectID
                ) as? Attachment,
                      requestedAttachment.id == requestedAttachmentId,
                      requestedAttachment.message?.id == messageId else {
                    return nil
                }

                return requestedAttachment.message?.attachmentsArray.compactMap { attachment in
                    guard let attachmentId = attachment.id,
                          attachmentId.hasPrefix("local_inline_"),
                          let payload = recoveredPayloads[attachmentId] else {
                        return nil
                    }

                    if let localURL = attachment.localURL,
                       AttachmentPaths.isReadableStoragePath(
                           localURL,
                           messageId: messageId,
                           attachmentId: attachmentId
                       ),
                       let fileURL = AttachmentPaths.fullURL(for: localURL),
                       FileManager.default.fileExists(atPath: fileURL.path) {
                        return nil
                    }

                    return Candidate(
                        objectID: attachment.objectID,
                        attachmentId: attachmentId,
                        payload: payload
                    )
                } ?? []
            }

            guard isActive(), let candidates else { return nil }
            guard !candidates.isEmpty else {
                // A sibling synthesized row may already have migrated every
                // payload in this message while this request was waiting.
                if let requestedPayload {
                    return requestedPayload.data
                }
                await markFailed(
                    attachmentObjectID: requestedAttachmentObjectID,
                    makeBackgroundContext: makeBackgroundContext,
                    isActive: isActive
                )
                Log.warning(
                    "Full-message recovery did not contain synthesized inline attachment \(requestedAttachmentId)",
                    category: .attachment
                )
                return nil
            }

            AttachmentPaths.setupDirectories()
            let processingTask: Task<[PersistenceResult], Never> = Task.detached(priority: .utility) {
                var results: [PersistenceResult] = []

                for candidate in candidates {
                    guard isActive() else {
                        Self.removeFiles(for: results)
                        return []
                    }

                    let filenameExtension = (candidate.payload.filename as NSString)
                        .pathExtension
                        .lowercased()
                    let ext = filenameExtension.isEmpty
                        ? AttachmentPaths.fileExtension(for: candidate.payload.mimeType)
                        : filenameExtension
                    let originalPath = AttachmentPaths.originalPath(
                        messageId: messageId,
                        attachmentId: candidate.attachmentId,
                        ext: ext
                    )
                    let potentialPreviewPath = AttachmentPaths.previewPath(
                        messageId: messageId,
                        attachmentId: candidate.attachmentId
                    )
                    let savedOriginal = AttachmentPaths.saveData(
                        candidate.payload.data,
                        to: originalPath
                    )

                    var width: Int16?
                    var height: Int16?
                    var pageCount: Int16?
                    var savedPreview = false

                    if savedOriginal, isActive() {
                        if candidate.payload.mimeType.hasPrefix("image/") {
                            if let dimensions = ImageProcessor.getImageDimensions(
                                from: candidate.payload.data
                            ) {
                                width = persistedImageDimension(dimensions.width)
                                height = persistedImageDimension(dimensions.height)
                            }
                            if let thumbnail = ImageProcessor.generateThumbnail(
                                from: candidate.payload.data,
                                mimeType: candidate.payload.mimeType
                            ), isActive() {
                                savedPreview = AttachmentPaths.saveData(
                                    thumbnail,
                                    to: potentialPreviewPath
                                )
                            }
                        } else if candidate.payload.mimeType == "application/pdf" {
                            if let count = ImageProcessor.getPDFPageCount(
                                from: candidate.payload.data
                            ) {
                                pageCount = persistedPDFPageCount(count)
                            }
                            if let thumbnail = ImageProcessor.generatePDFThumbnail(
                                from: candidate.payload.data
                            ), isActive() {
                                savedPreview = AttachmentPaths.saveData(
                                    thumbnail,
                                    to: potentialPreviewPath
                                )
                            }
                        }
                    }

                    results.append(
                        PersistenceResult(
                            objectID: candidate.objectID,
                            attachmentId: candidate.attachmentId,
                            originalPath: originalPath,
                            previewPath: savedPreview ? potentialPreviewPath : nil,
                            width: width,
                            height: height,
                            pageCount: pageCount,
                            savedOriginal: savedOriginal
                        )
                    )
                }

                guard isActive() else {
                    Self.removeFiles(for: results)
                    return []
                }
                return results
            }
            let persistenceResults = await withTaskCancellationHandler {
                await processingTask.value
            } onCancel: {
                processingTask.cancel()
            }
            guard isActive(), !persistenceResults.isEmpty else { return nil }

            let persistenceContext = makeBackgroundContext()
            let persistenceOutcome = await persistenceContext.perform {
                var requestedPersisted = false

                for result in persistenceResults {
                    guard let attachment = try? persistenceContext.existingObject(
                        with: result.objectID
                    ) as? Attachment,
                          attachment.id == result.attachmentId,
                          attachment.message?.id == messageId else {
                        continue
                    }

                    if result.savedOriginal {
                        attachment.localURL = result.originalPath
                        attachment.previewURL = result.previewPath
                        attachment.byteSize = Int64(
                            recoveredPayloads[result.attachmentId]?.data.count ?? 0
                        )
                        if let width = result.width { attachment.width = width }
                        if let height = result.height { attachment.height = height }
                        if let pageCount = result.pageCount { attachment.pageCount = pageCount }
                        attachment.state = .downloaded
                        attachment.lastDownloadFailedAt = nil
                        if result.objectID == requestedAttachmentObjectID {
                            requestedPersisted = true
                        }
                    } else if result.objectID == requestedAttachmentObjectID {
                        attachment.state = .failed
                        attachment.lastDownloadFailedAt = Date()
                    }
                }

                guard isActive() else {
                    persistenceContext.rollback()
                    return (saved: false, requestedPersisted: false)
                }
                do {
                    try persistenceContext.save()
                    return (saved: true, requestedPersisted: requestedPersisted)
                } catch {
                    persistenceContext.rollback()
                    Log.error(
                        "Failed to persist recovered synthesized inline attachments",
                        category: .attachment,
                        error: error
                    )
                    return (saved: false, requestedPersisted: false)
                }
            }

            if !persistenceOutcome.saved {
                Self.removeFiles(for: persistenceResults)
            }
            if let requestedPayload {
                return requestedPayload.data
            }
            await markFailed(
                attachmentObjectID: requestedAttachmentObjectID,
                makeBackgroundContext: makeBackgroundContext,
                isActive: isActive
            )
            Log.warning(
                "Full-message recovery did not contain synthesized inline attachment \(requestedAttachmentId)",
                category: .attachment
            )
            return nil
        } catch {
            guard !(error is CancellationError), isActive() else { return nil }
            await markFailed(
                attachmentObjectID: requestedAttachmentObjectID,
                makeBackgroundContext: makeBackgroundContext,
                isActive: isActive
            )
            Log.warning(
                "Failed to recover synthesized inline attachment \(requestedAttachmentId)",
                category: .attachment
            )
            return nil
        }
    }

    private static func markFailed(
        attachmentObjectID: NSManagedObjectID,
        makeBackgroundContext: @escaping @Sendable () -> NSManagedObjectContext,
        isActive: @escaping @Sendable () -> Bool
    ) async {
        guard isActive() else { return }
        let context = makeBackgroundContext()
        await context.perform {
            guard isActive(),
                  let attachment = try? context.existingObject(
                      with: attachmentObjectID
                  ) as? Attachment else {
                return
            }
            attachment.state = .failed
            attachment.lastDownloadFailedAt = Date()
            guard isActive() else {
                context.rollback()
                return
            }
            context.saveOrLog(
                operation: "mark synthesized inline attachment recovery failed",
                category: .attachment
            )
        }
    }

    private static func removeFiles(for results: [PersistenceResult]) {
        for result in results where result.savedOriginal {
            AttachmentPaths.deleteFile(at: result.originalPath)
            AttachmentPaths.deleteFile(at: result.previewPath)
        }
    }
}

@MainActor
final class AttachmentDownloader: ObservableObject {
    static let shared = AttachmentDownloader()

    @Published private var downloadProgressByKey: [AttachmentDownloadKey: Double] = [:]
    @Published private var activeDownloadKeys: Set<AttachmentDownloadKey> = []

    private let apiClient: any GmailAPIClientProtocol
    private let coreDataStack: CoreDataStack
    private var cancellables = Set<AnyCancellable>()
    private var retryAttempts: [AttachmentDownloadKey: Int] = [:]
    private struct DownloadOperation {
        let generation: AttachmentDownloadGenerationToken
        let task: Task<Void, Never>
    }

    private struct SynthesizedInlineRecoveryOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct AttachmentDownloadKey: Hashable {
        let messageId: String
        let attachmentId: String
    }

    private final class DownloadedDataBox {
        var data: Data?
    }

    private var activeDownloadOperations: [UUID: DownloadOperation] = [:]
    private var activeSynthesizedInlineRecoveries: [String: SynthesizedInlineRecoveryOperation] = [:]
    private var activeDownloadWaiters: [
        AttachmentDownloadKey: [UUID: CheckedContinuation<Void, Never>]
    ] = [:]
    private var acceptsNewDownloads = true
    private let maxRetryAttempts: Int
    private let baseRetryDelay: TimeInterval
    private let loadAttachmentData: @Sendable (String?) async -> Data?
    private let prepareDownloadDirectories: @Sendable () -> Void

    init(
        apiClient: (any GmailAPIClientProtocol)? = nil,
        coreDataStack: CoreDataStack = .shared,
        maxRetryAttempts: Int = 3,
        baseRetryDelay: TimeInterval = 2.0,
        loadAttachmentData: @escaping @Sendable (String?) async -> Data? = { path in
            await Task.detached(priority: .utility) {
                AttachmentPaths.loadData(from: path)
            }.value
        },
        prepareDownloadDirectories: @escaping @Sendable () -> Void = {
            AttachmentPaths.setupDirectories()
        }
    ) {
        self.apiClient = apiClient ?? GmailAPIClient.shared
        self.coreDataStack = coreDataStack
        self.maxRetryAttempts = maxRetryAttempts
        self.baseRetryDelay = baseRetryDelay
        self.loadAttachmentData = loadAttachmentData
        self.prepareDownloadDirectories = prepareDownloadDirectories
        prepareDownloadDirectories()
    }

    // MARK: - Cleanup

    /// Cleans up tracking data for a completed or cancelled download.
    /// Call this after a download finishes (success or failure) to prevent memory leaks.
    func cleanupDownload(messageId: String, attachmentId: String) {
        let key = AttachmentDownloadKey(
            messageId: messageId,
            attachmentId: attachmentId
        )
        downloadProgressByKey.removeValue(forKey: key)
        activeDownloadKeys.remove(key)
        retryAttempts.removeValue(forKey: key)
    }

    /// Cleans up all tracking data. Call on logout to prevent leaking previous user's data.
    func cleanupAll() {
        downloadProgressByKey.removeAll()
        activeDownloadKeys.removeAll()
        let waiters = activeDownloadWaiters.values.flatMap { $0.values }
        activeDownloadWaiters.removeAll()
        waiters.forEach { $0.resume() }
        retryAttempts.removeAll()
    }

    func isDownloading(messageId: String?, attachmentId: String?) -> Bool {
        guard let messageId, let attachmentId else { return false }
        return activeDownloadKeys.contains(
            AttachmentDownloadKey(
                messageId: messageId,
                attachmentId: attachmentId
            )
        )
    }

    func downloadProgress(messageId: String?, attachmentId: String?) -> Double? {
        guard let messageId, let attachmentId else { return nil }
        return downloadProgressByKey[
            AttachmentDownloadKey(
                messageId: messageId,
                attachmentId: attachmentId
            )
        ]
    }

    /// Starts the post-sync attachment sweep and registers it before returning,
    /// so account teardown can cancel and await every automatic downloader task.
    func schedulePendingAttachmentDownloads() {
        _ = startDownloadOperation { [weak self] generation in
            await self?.enqueueAllPendingAttachments(generation: generation)
        }
    }

    /// Reopens attachment work only after AuthSession has isolated the new
    /// account's store and is ready to publish authenticated UI.
    ///
    /// Returns false when a leaked download operation from the closed account
    /// is still outstanding. This transition's reopen has failed — the caller
    /// must fail the whole account reopen rather than publish a session whose
    /// attachment work cannot start. A later transition can still reopen once
    /// the outstanding operation unwinds.
    func reopenAdmission() -> Bool {
        guard activeDownloadOperations.isEmpty else {
            Log.error(
                "Refusing to reopen attachment downloads while operations from the closed account remain",
                category: .attachment
            )
            return false
        }
        // Sign-out removes the account-scoped directories. Recreate them
        // before same-process sign-in exposes any attachment work.
        prepareDownloadDirectories()
        acceptsNewDownloads = true
        return true
    }

    /// Invalidates every common download operation, cancels tasks owned by the
    /// downloader, and waits for all writers to unwind. New operations stay
    /// suspended until the next account's post-sync sweep is scheduled.
    func cancelAndAwaitAllDownloads() async {
        acceptsNewDownloads = false
        let operations = Array(activeDownloadOperations.values)
        operations.forEach {
            $0.generation.cancel()
            $0.task.cancel()
        }
        for operation in operations {
            await operation.task.value
        }
        cleanupAll()
    }

    private func startDownloadOperation(
        _ body: @escaping @MainActor (AttachmentDownloadGenerationToken) async -> Void
    ) -> Task<Void, Never>? {
        guard acceptsNewDownloads, !Task.isCancelled else { return nil }
        let id = UUID()
        let generation = AttachmentDownloadGenerationToken()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishDownloadOperation(id) }
            await body(generation)
        }
        activeDownloadOperations[id] = DownloadOperation(
            generation: generation,
            task: task
        )
        return task
    }

    private func finishDownloadOperation(_ id: UUID) {
        activeDownloadOperations.removeValue(forKey: id)
    }

    private func awaitDownloadOperation(_ task: Task<Void, Never>) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func isActive(_ generation: AttachmentDownloadGenerationToken) -> Bool {
        !Task.isCancelled && !generation.isCancelled
    }
    
    func enqueueAllPendingAttachments() async {
        guard let task = startDownloadOperation({ [weak self] generation in
            await self?.enqueueAllPendingAttachments(generation: generation)
        }) else { return }
        await awaitDownloadOperation(task)
    }

    private func enqueueAllPendingAttachments(
        generation: AttachmentDownloadGenerationToken
    ) async {
        guard isActive(generation) else { return }
        let context = coreDataStack.newBackgroundContext()

        // Extract needed data inside context.perform to avoid faulting on wrong thread
        let attachmentData: [(objectID: NSManagedObjectID, messageId: String)] = await context.perform {
            let request = NSFetchRequest<Attachment>(entityName: "Attachment")
            request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "stateRaw == %@", Attachment.State.queued.rawValue),
                NSPredicate(format: "id BEGINSWITH %@", "local_inline_")
            ])
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
                if attachment.id?.hasPrefix("local_inline_") == true,
                   attachment.state != .queued,
                   !attachment.needsRedownload {
                    return nil
                }
                return (attachment.objectID, message.id)
            }
        }

        guard isActive(generation) else { return }
        for data in attachmentData {
            guard isActive(generation) else { return }
            await performDownloadAttachment(
                attachmentObjectID: data.objectID,
                messageId: data.messageId,
                in: context,
                generation: generation
            )
        }
    }
    
    func downloadAttachment(attachmentObjectID: NSManagedObjectID, messageId: String, in context: NSManagedObjectContext) async {
        guard let task = startDownloadOperation({ [weak self] generation in
            await self?.performDownloadAttachment(
                attachmentObjectID: attachmentObjectID,
                messageId: messageId,
                in: context,
                generation: generation
            )
        }) else { return }
        await awaitDownloadOperation(task)
    }

    /// Downloads and reads an attachment under one account-scoped operation.
    /// CID rendering uses this so teardown cannot drain the writer and then
    /// race an unregistered Core Data lookup or file read in the continuation.
    func downloadAttachmentData(
        attachmentObjectID: NSManagedObjectID,
        messageId: String,
        in context: NSManagedObjectContext
    ) async -> Data? {
        let result = DownloadedDataBox()
        guard let task = startDownloadOperation({ [weak self] generation in
            guard let self else { return }
            await self.performDownloadAttachment(
                attachmentObjectID: attachmentObjectID,
                messageId: messageId,
                in: context,
                generation: generation
            )
            guard self.isActive(generation) else { return }

            let localPath: String? = await context.perform { () -> String? in
                guard let attachment = try? context.existingObject(
                    with: attachmentObjectID
                ) as? Attachment else {
                    return nil
                }
                // A concurrent caller may have joined a download performed in
                // another context. Refresh before reading its committed path;
                // otherwise this context can retain the pre-download nil.
                context.refresh(attachment, mergeChanges: true)
                guard attachment.state == .downloaded || attachment.state == .uploaded,
                      let attachmentId = attachment.id,
                      AttachmentPaths.isReadableStoragePath(
                          attachment.localURL,
                          messageId: messageId,
                          attachmentId: attachmentId
                      ) else {
                    return nil
                }
                return attachment.localURL
            }
            guard self.isActive(generation), localPath != nil else { return }

            let data = await self.loadAttachmentData(localPath)
            guard self.isActive(generation) else { return }
            result.data = data
        }) else { return nil }

        await awaitDownloadOperation(task)
        return result.data
    }

    private func performDownloadAttachment(
        attachmentObjectID: NSManagedObjectID,
        messageId: String,
        in context: NSManagedObjectContext,
        generation: AttachmentDownloadGenerationToken
    ) async {
        guard isActive(generation) else { return }
        let attachmentId = await context.perform {
            (try? context.existingObject(with: attachmentObjectID) as? Attachment)?.id
        }
        guard isActive(generation), let attachmentId = attachmentId else { return }

        // Skip downloading attachments with local IDs - these are from sent messages and don't exist on Gmail
        let didSkipLocal = await context.perform {
            guard !generation.isCancelled else { return false }
            guard let attachmentInContext = try? context.existingObject(with: attachmentObjectID) as? Attachment else {
                return false
            }
            if attachmentInContext.isLocalAttachment,
               !attachmentId.hasPrefix("local_inline_") {
                Log.debug("Skipping download for local attachment: \(attachmentId)", category: .attachment)
                attachmentInContext.state = .downloaded
                attachmentInContext.lastDownloadFailedAt = nil
                guard !generation.isCancelled else {
                    context.rollback()
                    return false
                }
                do {
                    try context.save()
                } catch {
                    Log.error("Failed to save local attachment state for \(attachmentId)", category: .attachment, error: error)
                }
                return true
            }
            return false
        }
        guard isActive(generation) else { return }
        if didSkipLocal { return }

        await downloadAttachmentWithRetry(
            attachmentId: attachmentId,
            attachmentObjectID: attachmentObjectID,
            messageId: messageId,
            in: context,
            generation: generation
        )
    }

    private func downloadAttachmentWithRetry(
        attachmentId: String,
        attachmentObjectID: NSManagedObjectID,
        messageId: String,
        in context: NSManagedObjectContext,
        generation: AttachmentDownloadGenerationToken,
        isRetryContinuation: Bool = false
    ) async {
        guard isActive(generation) else { return }
        let downloadKey = AttachmentDownloadKey(
            messageId: messageId,
            attachmentId: attachmentId
        )
        if !isRetryContinuation && activeDownloadKeys.contains(downloadKey) {
            Log.debug("Download already in progress for attachment: \(attachmentId)", category: .attachment)
            await waitForActiveDownload(downloadKey)
            return
        }

        if !isRetryContinuation {
            activeDownloadKeys.insert(downloadKey)
        }
        downloadProgressByKey[downloadKey] = 0.0
        defer {
            if !isRetryContinuation {
                activeDownloadKeys.remove(downloadKey)
                downloadProgressByKey.removeValue(forKey: downloadKey)
                let waiters = activeDownloadWaiters
                    .removeValue(forKey: downloadKey)
                    .map { Array($0.values) } ?? []
                waiters.forEach { $0.resume() }
            }
        }

        if attachmentId.hasPrefix("local_inline_") {
            let alreadyReadable = await context.perform {
                guard let attachment = try? context.existingObject(
                    with: attachmentObjectID
                ) as? Attachment else {
                    return false
                }
                context.refresh(attachment, mergeChanges: true)
                guard let localURL = attachment.localURL,
                      AttachmentPaths.isReadableStoragePath(
                          localURL,
                          messageId: messageId,
                          attachmentId: attachmentId
                      ),
                      let fileURL = AttachmentPaths.fullURL(for: localURL),
                      FileManager.default.fileExists(atPath: fileURL.path) else {
                    return false
                }
                attachment.state = .downloaded
                attachment.lastDownloadFailedAt = nil
                return context.saveOrLog(
                    operation: "confirm synthesized inline attachment storage",
                    category: .attachment
                )
            }
            guard isActive(generation) else { return }
            if alreadyReadable { return }

            await recoverSynthesizedInlineAttachments(
                messageId: messageId,
                requestedAttachmentObjectID: attachmentObjectID,
                requestedAttachmentId: attachmentId
            )
            guard isActive(generation) else { return }
            retryAttempts.removeValue(forKey: downloadKey)
            return
        }

        do {
            let attachmentInfo = await context.perform {
                guard let attachmentInContext = try? context.existingObject(with: attachmentObjectID) as? Attachment else {
                    return (mimeType: "application/octet-stream", filename: "")
                }
                return (mimeType: attachmentInContext.mimeType, filename: attachmentInContext.filename)
            }
            guard isActive(generation) else { return }

            // Download attachment data from Gmail. The API client's retry
            // loop is the single retry owner — no second loop here.
            let data = try await apiClient.getAttachment(messageId: messageId, attachmentId: attachmentId)
            guard isActive(generation) else {
                await rollbackPartialDownload(
                    messageId: messageId,
                    attachmentId: attachmentId
                )
                return
            }

            downloadProgressByKey[downloadKey] = 0.5
            
            // Generate file extension and paths
            // Prefer extension from original filename, fall back to MIME type mapping
            let mimeType = attachmentInfo.mimeType
            let filenameExt = (attachmentInfo.filename as NSString).pathExtension.lowercased()
            let ext = filenameExt.isEmpty ? AttachmentPaths.fileExtension(for: mimeType) : filenameExt
            let originalPath = AttachmentPaths.originalPath(
                messageId: messageId,
                attachmentId: attachmentId,
                ext: ext
            )
            let previewPath = AttachmentPaths.previewPath(
                messageId: messageId,
                attachmentId: attachmentId
            )

            // Process heavy work in background to avoid blocking main thread.
            // Detached work does not inherit parent cancellation, so explicitly
            // forward it and await unwinding before account cleanup continues.
            let processingTask: Task<(savedOriginal: Bool, width: Int16?, height: Int16?, pageCount: Int16?, savedPreview: Bool), Never> = Task.detached {
                guard !Task.isCancelled, !generation.isCancelled else {
                    return (false, nil, nil, nil, false)
                }
                // Save original file
                let savedOriginal = AttachmentPaths.saveData(data, to: originalPath)

                var width: Int16?
                var height: Int16?
                var pageCount: Int16?
                var savedPreview = false

                guard !Task.isCancelled, !generation.isCancelled else {
                    return (savedOriginal, nil, nil, nil, false)
                }

                if mimeType.starts(with: "image/") {
                    // Process image: get dimensions and create preview
                    if let dimensions = ImageProcessor.getImageDimensions(from: data) {
                        width = Int16(dimensions.width)
                        height = Int16(dimensions.height)
                    }

                    if !generation.isCancelled,
                       let thumbnailData = ImageProcessor.generateThumbnail(from: data, mimeType: mimeType),
                       !generation.isCancelled {
                        savedPreview = AttachmentPaths.saveData(thumbnailData, to: previewPath)
                    }
                } else if mimeType == "application/pdf" {
                    // Process PDF: get page count and create preview
                    if let count = ImageProcessor.getPDFPageCount(from: data) {
                        pageCount = Int16(count)
                    }

                    if !generation.isCancelled,
                       let thumbnailData = ImageProcessor.generatePDFThumbnail(from: data),
                       !generation.isCancelled {
                        savedPreview = AttachmentPaths.saveData(thumbnailData, to: previewPath)
                    }
                }

                return (savedOriginal, width, height, pageCount, savedPreview)
            }
            let processedResult = await withTaskCancellationHandler {
                await processingTask.value
            } onCancel: {
                processingTask.cancel()
            }

            guard isActive(generation) else {
                await rollbackPartialDownload(
                    messageId: messageId,
                    attachmentId: attachmentId,
                    exactOriginalPath: originalPath
                )
                return
            }

            let saveSucceeded = await context.perform {
                guard !generation.isCancelled else { return false }
                guard let attachmentInContext = try? context.existingObject(with: attachmentObjectID) as? Attachment else {
                    return false
                }

                if processedResult.savedOriginal {
                    attachmentInContext.localURL = originalPath
                } else {
                    Log.warning("Failed to save original attachment file for ID: \(attachmentId)", category: .attachment)
                    attachmentInContext.state = .failed
                    attachmentInContext.lastDownloadFailedAt = Date()
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
                // Never retain a legacy preview path after migration. Some
                // image/PDF payloads cannot produce a thumbnail; nil is a
                // valid final result and prevents needsRedownload from looping.
                attachmentInContext.previewURL = processedResult.savedPreview ? previewPath : nil

                if processedResult.savedOriginal {
                    attachmentInContext.state = .downloaded
                    attachmentInContext.lastDownloadFailedAt = nil
                }

                guard !generation.isCancelled else {
                    context.rollback()
                    return false
                }
                do {
                    try context.save()
                    return true
                } catch {
                    Log.error("Failed to save attachment updates for \(attachmentId)", category: .attachment, error: error)
                    return false
                }
            }

            guard isActive(generation) else {
                await rollbackPartialDownload(
                    messageId: messageId,
                    attachmentId: attachmentId,
                    exactOriginalPath: originalPath
                )
                return
            }

            if !saveSucceeded || !processedResult.savedOriginal {
                return
            }

            downloadProgressByKey[downloadKey] = 1.0
            
            // Clear retry attempts on success
            retryAttempts.removeValue(forKey: downloadKey)

        } catch {
            if error is CancellationError || !isActive(generation) {
                await rollbackPartialDownload(
                    messageId: messageId,
                    attachmentId: attachmentId
                )
                return
            }
            Log.error("Failed to download attachment \(attachmentId)", category: .attachment, error: error)

            // Rollback any partial download artifacts to prevent orphaned files
            await rollbackPartialDownload(
                messageId: messageId,
                attachmentId: attachmentId
            )

            // Check if we should retry
            let attempts = (retryAttempts[downloadKey] ?? 0) + 1
            retryAttempts[downloadKey] = attempts

            if attempts < maxRetryAttempts {
                // Calculate exponential backoff delay
                let delay = baseRetryDelay * pow(2.0, Double(attempts - 1))
                Log.debug("Retrying attachment \(attachmentId) in \(delay) seconds (attempt \(attempts)/\(maxRetryAttempts))", category: .attachment)

                // Schedule retry; a cancelled task abandons the retry chain
                // and unwinds into the outermost call's cleanup `defer`.
                guard await Task.sleepUnlessCancelled(nanoseconds: UInt64(delay * 1_000_000_000)) else { return }
                guard isActive(generation) else { return }

                // Retry the download
                await downloadAttachmentWithRetry(
                    attachmentId: attachmentId,
                    attachmentObjectID: attachmentObjectID,
                    messageId: messageId,
                    in: context,
                    generation: generation,
                    isRetryContinuation: true
                )
                return
            } else {
                // Immediate retry budget is exhausted; later callers may retry based on this timestamp.
                Log.warning("Attachment \(attachmentId) failed after \(maxRetryAttempts) attempts", category: .attachment)
                await context.perform {
                    guard !generation.isCancelled else { return }
                    if let attachmentInContext = try? context.existingObject(with: attachmentObjectID) as? Attachment {
                        attachmentInContext.state = .failed
                        attachmentInContext.lastDownloadFailedAt = Date()
                        guard !generation.isCancelled else {
                            context.rollback()
                            return
                        }
                        do {
                            try context.save()
                        } catch {
                            Log.error("Failed to save failed attachment state for \(attachmentId)", category: .attachment, error: error)
                        }
                    }
                }
                guard isActive(generation) else { return }
                retryAttempts.removeValue(forKey: downloadKey)
            }
        }
    }

    /// Full-message recovery migrates every synthesized inline sibling in the
    /// message. Coalesce only this bulk path by message; ordinary Gmail-backed
    /// downloads retain their message-and-attachment key above.
    private func recoverSynthesizedInlineAttachments(
        messageId: String,
        requestedAttachmentObjectID: NSManagedObjectID,
        requestedAttachmentId: String
    ) async {
        let operation: SynthesizedInlineRecoveryOperation
        if let activeOperation = activeSynthesizedInlineRecoveries[messageId] {
            operation = activeOperation
        } else {
            let operationID = UUID()
            let apiClient = self.apiClient
            let coreDataStack = self.coreDataStack
            guard let task = startDownloadOperation({ [weak self] recoveryGeneration in
                _ = await SynthesizedInlineAttachmentRecovery.recover(
                    messageId: messageId,
                    requestedAttachmentObjectID: requestedAttachmentObjectID,
                    requestedAttachmentId: requestedAttachmentId,
                    apiClient: apiClient,
                    makeBackgroundContext: {
                        coreDataStack.newBackgroundContext()
                    },
                    isActive: {
                        !recoveryGeneration.isCancelled && !Task.isCancelled
                    }
                )
                self?.finishSynthesizedInlineRecovery(
                    messageId: messageId,
                    operationID: operationID
                )
            }) else {
                return
            }
            operation = SynthesizedInlineRecoveryOperation(
                id: operationID,
                task: task
            )
            activeSynthesizedInlineRecoveries[messageId] = operation
        }

        await awaitValueUnlessCancelled(of: operation.task, cancellationValue: ())
    }

    private func finishSynthesizedInlineRecovery(
        messageId: String,
        operationID: UUID
    ) {
        if activeSynthesizedInlineRecoveries[messageId]?.id == operationID {
            activeSynthesizedInlineRecoveries[messageId] = nil
        }
    }

    private func waitForActiveDownload(_ key: AttachmentDownloadKey) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                activeDownloadWaiters[key, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelActiveDownloadWaiter(waiterID, for: key)
            }
        }
    }

    private func cancelActiveDownloadWaiter(
        _ waiterID: UUID,
        for key: AttachmentDownloadKey
    ) {
        guard let continuation = activeDownloadWaiters[key]?.removeValue(
            forKey: waiterID
        ) else {
            return
        }
        if activeDownloadWaiters[key]?.isEmpty == true {
            activeDownloadWaiters.removeValue(forKey: key)
        }
        continuation.resume()
    }
    
    func retryFailedDownload(for attachment: Attachment) async {
        guard let task = startDownloadOperation({ [weak self] generation in
            await self?.performRetryFailedDownload(for: attachment, generation: generation)
        }) else { return }
        await awaitDownloadOperation(task)
    }

    private func performRetryFailedDownload(
        for attachment: Attachment,
        generation: AttachmentDownloadGenerationToken
    ) async {
        guard isActive(generation) else { return }
        guard let message = attachment.message,
              let attachmentId = attachment.id else { return }
        let attachmentObjectID = attachment.objectID

        // Reset retry counter for manual retry
        retryAttempts.removeValue(
            forKey: AttachmentDownloadKey(
                messageId: message.id,
                attachmentId: attachmentId
            )
        )

        let context = coreDataStack.newBackgroundContext()
        let saveSucceeded = await context.perform {
            guard !generation.isCancelled else { return false }
            guard let attachmentInContext = try? context.existingObject(with: attachmentObjectID) as? Attachment else {
                return false
            }
            attachmentInContext.state = .queued
            guard !generation.isCancelled else {
                context.rollback()
                return false
            }
            do {
                try context.save()
                return true
            } catch {
                Log.warning("Failed to save attachment for retry", category: .attachment)
                return false
            }
        }
        guard saveSucceeded, isActive(generation) else { return }
        await performDownloadAttachment(
            attachmentObjectID: attachmentObjectID,
            messageId: message.id,
            in: context,
            generation: generation
        )
    }
    
    func downloadAttachmentIfNeeded(for attachment: Attachment) async {
        guard let task = startDownloadOperation({ [weak self] generation in
            await self?.performDownloadAttachmentIfNeeded(for: attachment, generation: generation)
        }) else { return }
        await awaitDownloadOperation(task)
    }

    private func performDownloadAttachmentIfNeeded(
        for attachment: Attachment,
        generation: AttachmentDownloadGenerationToken
    ) async {
        guard isActive(generation) else { return }
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
            guard !generation.isCancelled else { return false }
            guard let attachmentInContext = try? context.existingObject(with: attachmentObjectID) as? Attachment else {
                return false
            }

            if attachmentInContext.state == .downloaded || attachmentInContext.state == .uploaded {
                attachmentInContext.state = .queued
            }

            guard !generation.isCancelled else {
                context.rollback()
                return false
            }
            do {
                try context.save()
                return true
            } catch {
                Log.warning("Failed to save attachment state for download check", category: .attachment)
                return false
            }
        }
        guard shouldProceed, isActive(generation) else { return }
        await performDownloadAttachment(
            attachmentObjectID: attachmentObjectID,
            messageId: message.id,
            in: context,
            generation: generation
        )
    }
    
    /// Cleans up any partial download artifacts to prevent orphaned files.
    /// Called when a download fails to ensure clean state for retry.
    private func rollbackPartialDownload(
        messageId: String,
        attachmentId: String,
        exactOriginalPath: String? = nil
    ) async {
        if let exactOriginalPath,
           let originalURL = AttachmentPaths.fullURL(for: exactOriginalPath) {
            FileSystemErrorHandler.removeItem(at: originalURL, category: .attachment)
        }

        // Remove any partial original file (all possible extensions)
        let commonExtensions = ["", "jpg", "jpeg", "png", "gif", "pdf", "doc", "docx", "dat"]
        for ext in commonExtensions {
            let originalPath = AttachmentPaths.originalPath(
                messageId: messageId,
                attachmentId: attachmentId,
                ext: ext
            )
            if let originalURL = AttachmentPaths.fullURL(for: originalPath) {
                FileSystemErrorHandler.removeItem(at: originalURL, category: .attachment)
            }
        }

        // Remove any partial preview file
        let previewPath = AttachmentPaths.previewPath(
            messageId: messageId,
            attachmentId: attachmentId
        )
        if let previewURL = AttachmentPaths.fullURL(for: previewPath) {
            FileSystemErrorHandler.removeItem(at: previewURL, category: .attachment)
        }

        // Clear from in-memory cache before the operation releases teardown's
        // drain boundary; otherwise an old task can evict a new-account entry.
        await AttachmentCacheActor.shared.removeFromCache(
            messageId: messageId,
            attachmentId: attachmentId
        )
    }

    /// Cleans up orphaned attachment files that no longer have corresponding Core Data entities.
    /// Runs all operations in background to avoid blocking the main thread.
    func cleanupOrphanedFiles() async {
        guard let task = startDownloadOperation({ [weak self] generation in
            await self?.performCleanupOrphanedFiles(generation: generation)
        }) else { return }
        await awaitDownloadOperation(task)
    }

    private func performCleanupOrphanedFiles(
        generation: AttachmentDownloadGenerationToken
    ) async {
        guard isActive(generation) else { return }
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

        guard isActive(generation) else { return }

        // This account-scoped deleter participates in the same teardown drain
        // as downloads and CID persistence.
        let cleanupTask = Task.detached {
            guard !Task.isCancelled, !generation.isCancelled else { return }
            // Clean attachments folder
            let attachmentsURL = appSupportURL.appendingPathComponent("Attachments")
            let attachmentContents = FileSystemErrorHandler.contentsOfDirectory(at: attachmentsURL, category: .attachment)
            for fileURL in attachmentContents {
                guard !Task.isCancelled, !generation.isCancelled else { return }
                let relativePath = AttachmentPaths.relativePath(from: fileURL)
                if let path = relativePath, !validFiles.contains(path) {
                    guard !generation.isCancelled else { return }
                    FileSystemErrorHandler.removeItem(at: fileURL, category: .attachment)
                }
            }

            guard !Task.isCancelled, !generation.isCancelled else { return }
            // Clean previews folder
            let previewsURL = appSupportURL.appendingPathComponent("Previews")
            let previewContents = FileSystemErrorHandler.contentsOfDirectory(at: previewsURL, category: .attachment)
            for fileURL in previewContents {
                guard !Task.isCancelled, !generation.isCancelled else { return }
                let relativePath = AttachmentPaths.relativePath(from: fileURL)
                if let path = relativePath, !validFiles.contains(path) {
                    guard !generation.isCancelled else { return }
                    FileSystemErrorHandler.removeItem(at: fileURL, category: .attachment)
                }
            }
        }
        await withTaskCancellationHandler {
            await cleanupTask.value
        } onCancel: {
            cleanupTask.cancel()
        }
    }
}
