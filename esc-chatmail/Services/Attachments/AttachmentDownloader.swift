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
        /// The original or its preview found no room on the disk; neither is kept
        /// (`AttachmentWriteResult.outOfSpace`).
        let outOfSpace: Bool
    }

    static func recover(
        messageId: String,
        requestedAttachmentObjectID: NSManagedObjectID,
        requestedAttachmentId: String,
        apiClient: any GmailAPIClientProtocol,
        makeBackgroundContext: @escaping @Sendable () -> NSManagedObjectContext,
        isActive: @escaping @Sendable () -> Bool = { !Task.isCancelled },
        writeData: @escaping @Sendable (Data, String) -> AttachmentWriteResult = { data, path in
            AttachmentPaths.writeData(data, to: path)
        },
        storeClone: @escaping @Sendable (String, String) -> AttachmentWriteResult = { source, destination in
            AttachmentPaths.storeClone(ofFileAt: source, at: destination)
        },
        requestedFoundNoRoom: @escaping @Sendable () -> Void = {}
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
                    "Full-message recovery did not contain synthesized inline attachment \(Log.hashIdentifier(requestedAttachmentId))",
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

                    let ext = AttachmentPaths.storedFileExtension(
                        filename: candidate.payload.filename,
                        mimeType: candidate.payload.mimeType
                    )
                    let originalPath = AttachmentPaths.originalPath(
                        messageId: messageId,
                        attachmentId: candidate.attachmentId,
                        ext: ext
                    )
                    let potentialPreviewPath = AttachmentPaths.previewPath(
                        messageId: messageId,
                        attachmentId: candidate.attachmentId
                    )
                    let originalWrite = writeData(candidate.payload.data, originalPath)
                    var savedOriginal = originalWrite == .saved
                    var outOfSpace = originalWrite == .outOfSpace

                    var width: Int16?
                    var height: Int16?
                    var pageCount: Int16?
                    var savedPreview = false

                    if savedOriginal, isActive() {
                        if candidate.payload.mimeType.hasPrefix("image/") {
                            if let dimensions = ImageProcessor.getImageDimensions(
                                from: candidate.payload.data
                            ) {
                                let persisted = AttachmentMetadataBounds
                                    .persistedImageDimensions(dimensions)
                                width = persisted.width
                                height = persisted.height
                            }
                            if let preview = ImageProcessor.preview(
                                from: candidate.payload.data,
                                mimeType: candidate.payload.mimeType
                            ), isActive() {
                                let previewWrite: AttachmentWriteResult
                                switch preview {
                                case .original:
                                    // The original's own bytes: a clone of its file.
                                    previewWrite = storeClone(originalPath, potentialPreviewPath)
                                case .encoded(let thumbnail):
                                    previewWrite = writeData(thumbnail, potentialPreviewPath)
                                }
                                savedPreview = previewWrite == .saved
                                outOfSpace = previewWrite == .outOfSpace
                            }
                        } else if candidate.payload.mimeType == "application/pdf" {
                            if let count = ImageProcessor.getPDFPageCount(
                                from: candidate.payload.data
                            ) {
                                pageCount = AttachmentMetadataBounds.persistedPDFPageCount(count)
                            }
                            if let thumbnail = ImageProcessor.generatePDFThumbnail(
                                from: candidate.payload.data
                            ), isActive() {
                                let previewWrite = writeData(thumbnail, potentialPreviewPath)
                                savedPreview = previewWrite == .saved
                                outOfSpace = previewWrite == .outOfSpace
                            }
                        }
                    }
                    // A preview that did not fit takes its original with it, as in an
                    // ordinary download: the row stays as it was, to be recovered again
                    // once there is room, never downloaded with no preview for good.
                    if outOfSpace, savedOriginal {
                        AttachmentPaths.deleteFile(at: originalPath)
                        savedOriginal = false
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
                            savedOriginal: savedOriginal,
                            outOfSpace: outOfSpace
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
                    } else if result.objectID == requestedAttachmentObjectID, !result.outOfSpace {
                        // A full disk leaves the row as it was (`AttachmentWriteResult`).
                        attachment.state = .failed
                        attachment.lastDownloadFailedAt = Date()
                    } else if result.objectID == requestedAttachmentObjectID {
                        // Left as it was; the caller shows the refusal.
                        requestedFoundNoRoom()
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
                "Full-message recovery did not contain synthesized inline attachment \(Log.hashIdentifier(requestedAttachmentId))",
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
                "Failed to recover synthesized inline attachment \(Log.hashIdentifier(requestedAttachmentId))",
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

/// Downloads a received attachment only when something asks for it: a chat that
/// shows it (each attachment view's `onAppear`), a tap on Retry, an inline image
/// a bubble needs (`InlineAttachmentDownloadTrigger`), a `cid:` reference the
/// reader renders, or a forward that copies it (`ChatViewModel.setMessageToForward`).
/// Nothing downloads ahead of time, on any network: there is no post-sync sweep
/// (architecture review 2026-11, attachments-storage-disk#3, Kevin's call), so a
/// received row stays `queued` until it is shown, and mail never opened costs
/// neither disk nor data.
@MainActor
final class AttachmentDownloader: ObservableObject {
    static let shared = AttachmentDownloader()

    // Not @Published: nothing renders `downloadProgress(messageId:attachmentId:)`
    // (views read only `isDownloading`), and publishing the 0.5 / 1.0 progress
    // writes invalidated every attachment view observing this object for no
    // rendered change.
    private var downloadProgressByKey: [AttachmentDownloadKey: Double] = [:]
    @Published private var activeDownloadKeys: Set<AttachmentDownloadKey> = []
    /// The attachments whose last download was refused, or stopped, for want of space
    /// (`AttachmentDownloadSpacePolicy`, `AttachmentWriteResult.outOfSpace`). In memory only: the
    /// row's stored state is left as it was, and the views show "Not enough storage" with a
    /// Retry from this (`AttachmentDownloadIndicatorPolicy`). Cleared when a download of it is
    /// admitted, and for every attachment at an account transition (`cleanupAll`).
    @Published private var spaceRefusedKeys: Set<AttachmentDownloadKey> = []

    private let apiClient: any GmailAPIClientProtocol
    private let coreDataStack: CoreDataStack
    private var cancellables = Set<AnyCancellable>()
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
    private let loadAttachmentData: @Sendable (String?) async -> Data?
    private let prepareDownloadDirectories: @Sendable () -> Void
    private let fetchAttachmentFileReferences: @Sendable (NSManagedObjectContext) throws -> [NSDictionary]
    /// The volume's free space (`StoreVolumeFreeSpace`), read before each download and off
    /// the main actor: the volume query was never timed. Nil when it could not be read.
    private let availableStorageBytes: @Sendable () async -> Int64?
    /// The writer of a download's encoded preview, and of the inline recovery's originals:
    /// `AttachmentPaths.writeData`. A download's original is the downloaded file, renamed into
    /// place (`storeDownloadedFile`).
    private let writeAttachmentData: @Sendable (Data, String) -> AttachmentWriteResult
    /// The writer of a preview that is its original's own bytes, as a clone of the original's
    /// file (source path, destination path): `AttachmentPaths.storeClone`.
    private let storeAttachmentClone: @Sendable (String, String) -> AttachmentWriteResult
    /// What moves a downloaded file into the original's path: `AttachmentPaths.storeDownloadedFile`.
    private let storeDownloadedFile: @Sendable (URL, String) -> AttachmentWriteResult

    /// Orphans younger than this survive the sweep and are judged by a later
    /// one. Every writer (a download, CID persistence, inline recovery) writes
    /// its file before saving the row that names it, so a file whose row
    /// lands after the sweep's database snapshot looks orphaned for that
    /// window; thumbnailing a large PDF can hold it open for seconds.
    nonisolated static let orphanSweepRecentFileGracePeriod: TimeInterval = 60 * 60

    init(
        apiClient: (any GmailAPIClientProtocol)? = nil,
        coreDataStack: CoreDataStack = .shared,
        loadAttachmentData: @escaping @Sendable (String?) async -> Data? = { path in
            await Task.detached(priority: .utility) {
                AttachmentPaths.loadData(from: path)
            }.value
        },
        prepareDownloadDirectories: @escaping @Sendable () -> Void = {
            AttachmentPaths.setupDirectories()
        },
        fetchAttachmentFileReferences: @escaping @Sendable (NSManagedObjectContext) throws -> [NSDictionary] = { context in
            let request = NSFetchRequest<NSDictionary>(entityName: "Attachment")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["localURL", "previewURL"]
            return try context.fetch(request)
        },
        availableStorageBytes: @escaping @Sendable () async -> Int64? = {
            await Task.detached(priority: .utility) {
                StoreVolumeFreeSpace.availableBytes()
            }.value
        },
        writeAttachmentData: @escaping @Sendable (Data, String) -> AttachmentWriteResult = { data, path in
            AttachmentPaths.writeData(data, to: path)
        },
        storeAttachmentClone: @escaping @Sendable (String, String) -> AttachmentWriteResult = { source, destination in
            AttachmentPaths.storeClone(ofFileAt: source, at: destination)
        },
        storeDownloadedFile: @escaping @Sendable (URL, String) -> AttachmentWriteResult = { file, path in
            AttachmentPaths.storeDownloadedFile(at: file, as: path)
        }
    ) {
        self.apiClient = apiClient ?? GmailAPIClient.shared
        self.coreDataStack = coreDataStack
        self.loadAttachmentData = loadAttachmentData
        self.prepareDownloadDirectories = prepareDownloadDirectories
        self.fetchAttachmentFileReferences = fetchAttachmentFileReferences
        self.availableStorageBytes = availableStorageBytes
        self.writeAttachmentData = writeAttachmentData
        self.storeAttachmentClone = storeAttachmentClone
        self.storeDownloadedFile = storeDownloadedFile
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
    }

    /// Cleans up all tracking data. Call on logout to prevent leaking previous user's data.
    func cleanupAll() {
        downloadProgressByKey.removeAll()
        activeDownloadKeys.removeAll()
        spaceRefusedKeys.removeAll()
        let waiters = activeDownloadWaiters.values.flatMap { $0.values }
        activeDownloadWaiters.removeAll()
        waiters.forEach { $0.resume() }
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

    /// Whether the attachment's last download was refused, or stopped, for want of space.
    func isRefusedForSpace(messageId: String?, attachmentId: String?) -> Bool {
        guard let messageId, let attachmentId else { return false }
        return spaceRefusedKeys.contains(
            AttachmentDownloadKey(messageId: messageId, attachmentId: attachmentId)
        )
    }

    private func recordSpaceRefusal(messageId: String, attachmentId: String) {
        let key = AttachmentDownloadKey(messageId: messageId, attachmentId: attachmentId)
        if !spaceRefusedKeys.contains(key) {
            spaceRefusedKeys.insert(key)
        }
    }

    private func clearSpaceRefusal(messageId: String, attachmentId: String) {
        let key = AttachmentDownloadKey(messageId: messageId, attachmentId: attachmentId)
        // `Set.remove` of an absent key still publishes.
        if spaceRefusedKeys.contains(key) {
            spaceRefusedKeys.remove(key)
        }
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
    /// refused until `reopenAdmission()` lets the next account's downloads in.
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

    /// Whether the volume has room for a download of `byteSize` bytes
    /// (`AttachmentDownloadSpacePolicy`), asked before anything is fetched. A refusal writes
    /// nothing to the row: a received attachment's `queued` is its resting state, and the next
    /// showing asks again.
    private func hasRoomToDownload(byteSize: Int64, messageId: String, attachmentId: String) async -> Bool {
        let availableBytes = await availableStorageBytes()
        guard AttachmentDownloadSpacePolicy.admitsDownload(
            byteSize: byteSize,
            availableBytes: availableBytes
        ) else {
            Log.warning(
                "Not downloading attachment \(Log.hashIdentifier(attachmentId)): the disk is below its free-space floor",
                category: .attachment
            )
            recordSpaceRefusal(messageId: messageId, attachmentId: attachmentId)
            return false
        }
        clearSpaceRefusal(messageId: messageId, attachmentId: attachmentId)
        return true
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

        await performAttachmentDownload(
            attachmentId: attachmentId,
            attachmentObjectID: attachmentObjectID,
            messageId: messageId,
            in: context,
            generation: generation
        )
    }

    private func performAttachmentDownload(
        attachmentId: String,
        attachmentObjectID: NSManagedObjectID,
        messageId: String,
        in context: NSManagedObjectContext,
        generation: AttachmentDownloadGenerationToken
    ) async {
        guard isActive(generation) else { return }
        let downloadKey = AttachmentDownloadKey(
            messageId: messageId,
            attachmentId: attachmentId
        )
        if activeDownloadKeys.contains(downloadKey) {
            Log.debug("Download already in progress for attachment: \(attachmentId)", category: .attachment)
            await waitForActiveDownload(downloadKey)
            return
        }

        activeDownloadKeys.insert(downloadKey)
        downloadProgressByKey[downloadKey] = 0.0
        defer {
            // `Set.remove` of an absent key still publishes; a cancel may
            // already have removed it.
            if activeDownloadKeys.contains(downloadKey) {
                activeDownloadKeys.remove(downloadKey)
            }
            downloadProgressByKey.removeValue(forKey: downloadKey)
            let waiters = activeDownloadWaiters
                .removeValue(forKey: downloadKey)
                .map { Array($0.values) } ?? []
            waiters.forEach { $0.resume() }
        }

        if attachmentId.hasPrefix("local_inline_") {
            let storage = await context.perform { () -> (alreadyReadable: Bool, byteSize: Int64) in
                guard let attachment = try? context.existingObject(
                    with: attachmentObjectID
                ) as? Attachment else {
                    return (false, 0)
                }
                // The recovery writes every synthesized sibling of the message, so the floor is
                // asked about all of them, not this row alone.
                let siblingsBytes = attachment.message?.attachmentsArray
                    .filter { $0.id?.hasPrefix("local_inline_") == true }
                    .reduce(Int64(0)) { $0 + max(0, $1.byteSize) } ?? attachment.byteSize
                context.refresh(attachment, mergeChanges: true)
                guard let localURL = attachment.localURL,
                      AttachmentPaths.isReadableStoragePath(
                          localURL,
                          messageId: messageId,
                          attachmentId: attachmentId
                      ),
                      let fileURL = AttachmentPaths.fullURL(for: localURL),
                      FileManager.default.fileExists(atPath: fileURL.path) else {
                    return (false, siblingsBytes)
                }
                attachment.state = .downloaded
                attachment.lastDownloadFailedAt = nil
                return (
                    context.saveOrLog(
                        operation: "confirm synthesized inline attachment storage",
                        category: .attachment
                    ),
                    siblingsBytes
                )
            }
            guard isActive(generation) else { return }
            if storage.alreadyReadable { return }
            // The recovery fetches the whole message and writes every synthesized sibling.
            guard await hasRoomToDownload(byteSize: storage.byteSize, messageId: messageId, attachmentId: attachmentId),
                  isActive(generation) else {
                return
            }

            await recoverSynthesizedInlineAttachments(
                messageId: messageId,
                requestedAttachmentObjectID: attachmentObjectID,
                requestedAttachmentId: attachmentId
            )
            return
        }

        do {
            let attachmentInfo = await context.perform {
                guard let attachmentInContext = try? context.existingObject(with: attachmentObjectID) as? Attachment else {
                    return (mimeType: "application/octet-stream", filename: "", byteSize: Int64(0))
                }
                return (
                    mimeType: attachmentInContext.mimeType,
                    filename: attachmentInContext.filename,
                    byteSize: attachmentInContext.byteSize
                )
            }
            guard isActive(generation) else { return }
            guard await hasRoomToDownload(byteSize: attachmentInfo.byteSize, messageId: messageId, attachmentId: attachmentId),
                  isActive(generation) else {
                return
            }

            // Download the attachment to a file in `Attachments`, never into memory whole
            // (`GmailAPIClient.downloadAttachmentFile`, on its transfer session). The API
            // client's retry engine is the single retry owner: no second loop here.
            guard let attachmentsDirectory = AttachmentPaths.fullURL(for: AttachmentPaths.attachmentsFolder) else {
                return
            }
            let downloadedFile = try await apiClient.downloadAttachmentFile(
                messageId: messageId,
                attachmentId: attachmentId,
                into: attachmentsDirectory
            )
            // Moved into place below; anything left of it, on any path out of here, is removed.
            defer { try? FileManager.default.removeItem(at: downloadedFile) }
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
            let ext = AttachmentPaths.storedFileExtension(filename: attachmentInfo.filename, mimeType: mimeType)
            let originalPath = AttachmentPaths.originalPath(
                messageId: messageId,
                attachmentId: attachmentId,
                ext: ext
            )
            // A row whose original is already on disk here can be downloaded again (a legacy
            // preview path makes it `needsRedownload`); a download that then finds no room leaves
            // that original as it was.
            let originalExistedBefore = AttachmentPaths.fullURL(for: originalPath).map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
            let previewPath = AttachmentPaths.previewPath(
                messageId: messageId,
                attachmentId: attachmentId
            )

            // Process heavy work in background to avoid blocking main thread.
            // Detached work does not inherit parent cancellation, so explicitly
            // forward it and await unwinding before account cleanup continues.
            let writeAttachmentData = self.writeAttachmentData
            let storeAttachmentClone = self.storeAttachmentClone
            let storeDownloadedFile = self.storeDownloadedFile
            let processingTask: Task<(savedOriginal: Bool, width: Int16?, height: Int16?, pageCount: Int16?, savedPreview: Bool, outOfSpace: Bool), Never> = Task.detached {
                guard !Task.isCancelled, !generation.isCancelled else {
                    return (false, nil, nil, nil, false, false)
                }
                // The downloaded file becomes the original, by a rename: its bytes are not
                // written again.
                let originalWrite = storeDownloadedFile(downloadedFile, originalPath)
                let savedOriginal = originalWrite == .saved
                // Read through a mapping of the stored file, so a large original is paged in as
                // the dimensions and the preview read it, never held whole on the heap.
                var data = Data()
                if savedOriginal {
                    if let mapped = AttachmentPaths.fullURL(for: originalPath)
                        .flatMap({ try? Data(contentsOf: $0, options: .alwaysMapped) }) {
                        data = mapped
                    } else {
                        // The original is stored but could not be read back: the row is saved
                        // downloaded with no preview, which its next showing does not repair.
                        Log.warning(
                            "Attachment \(Log.hashIdentifier(attachmentId)) was stored but could not be read for its preview",
                            category: .attachment
                        )
                    }
                }

                var width: Int16?
                var height: Int16?
                var pageCount: Int16?
                var savedPreview = false

                guard originalWrite != .outOfSpace else {
                    return (false, nil, nil, nil, false, true)
                }
                guard !Task.isCancelled, !generation.isCancelled else {
                    return (savedOriginal, nil, nil, nil, false, false)
                }

                if mimeType.starts(with: "image/") {
                    // Process image: get dimensions and create preview
                    // The size is the sender's: never convert it with a trapping
                    // `Int16(_:)`, which crash-looped the app on a 40,000-pixel side.
                    if let dimensions = ImageProcessor.getImageDimensions(from: data) {
                        let persisted = AttachmentMetadataBounds.persistedImageDimensions(dimensions)
                        width = persisted.width
                        height = persisted.height
                    }

                    if !generation.isCancelled,
                       let preview = ImageProcessor.preview(from: data, mimeType: mimeType),
                       !generation.isCancelled {
                        let previewWrite: AttachmentWriteResult
                        switch preview {
                        case .original:
                            // An image of 1,600 px or less is its own preview: a clone of the
                            // original's file, which shares its blocks, never its bytes written
                            // a second time (`AttachmentPaths.storeClone`).
                            previewWrite = savedOriginal
                                ? storeAttachmentClone(originalPath, previewPath)
                                : .failed
                        case .encoded(let thumbnailData):
                            previewWrite = writeAttachmentData(thumbnailData, previewPath)
                        }
                        guard previewWrite != .outOfSpace else {
                            return (false, nil, nil, nil, false, true)
                        }
                        savedPreview = previewWrite == .saved
                    }
                } else if mimeType == "application/pdf" {
                    // Process PDF: get page count and create preview
                    if let count = ImageProcessor.getPDFPageCount(from: data) {
                        pageCount = AttachmentMetadataBounds.persistedPDFPageCount(count)
                    }

                    if !generation.isCancelled,
                       let thumbnailData = ImageProcessor.generatePDFThumbnail(from: data),
                       !generation.isCancelled {
                        let previewWrite = writeAttachmentData(thumbnailData, previewPath)
                        guard previewWrite != .outOfSpace else {
                            return (false, nil, nil, nil, false, true)
                        }
                        savedPreview = previewWrite == .saved
                    }
                }

                return (savedOriginal, width, height, pageCount, savedPreview, false)
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

            // The disk filled while this download was written: the original or its preview
            // found no room. Nothing of it is kept, and the row is left as it was, `queued`,
            // never marked failed and never retried here; the next showing asks again, and
            // the free-space floor answers it before anything is fetched. A preview that did
            // not fit takes the original with it, or the image would end downloaded with no
            // preview for good (`AttachmentThumbnailLoader.load` reads only the preview).
            if processedResult.outOfSpace {
                Log.warning(
                    "Attachment \(Log.hashIdentifier(attachmentId)) did not fit on the disk; left as it was",
                    category: .attachment
                )
                recordSpaceRefusal(messageId: messageId, attachmentId: attachmentId)
                if originalExistedBefore {
                    // The original the row already had is kept; only a preview this download
                    // wrote goes. An atomic write that found no room left the file it would have
                    // replaced in place.
                    AttachmentPaths.deleteFile(at: previewPath)
                    await AttachmentCacheActor.shared.removeFromCache(
                        messageId: messageId,
                        attachmentId: attachmentId
                    )
                } else {
                    await rollbackPartialDownload(
                        messageId: messageId,
                        attachmentId: attachmentId,
                        exactOriginalPath: originalPath
                    )
                }
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

        } catch {
            if error is CancellationError || !isActive(generation) {
                await rollbackPartialDownload(
                    messageId: messageId,
                    attachmentId: attachmentId
                )
                return
            }
            // The disk filled while the response or the decoded file was written: as for a
            // write that found no room (`AttachmentWriteResult.outOfSpace`), nothing is kept and
            // the row is left as it was, never marked failed.
            if StorageErrorClassifier.isOutOfSpace(error) {
                Log.warning(
                    "Attachment \(Log.hashIdentifier(attachmentId)) did not fit on the disk while it downloaded; left queued",
                    category: .attachment
                )
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

            // One call of the client, whose retry engine is the single retry owner
            // (`performRetryingRequest`: the 401 refresh, the 429 pacing, the transport
            // retries). Until 2026-11-27 a second loop here re-ran the whole download
            // twice more, 2 s and 4 s apart, so a large attachment on a slow link made
            // up to six 60-second transfers before this write, and a failed card
            // started them again on its next appearance (architecture review 2026-11,
            // attachments-storage-disk#2, first step). The row goes `.failed` and the
            // time is recorded; nothing reads the time yet: the next appearance decides
            // on the state alone (`downloadAttachmentIfNeeded`) and Retry sets
            // `.queued`, so a failed card is tried again as soon as it is shown.
            Log.warning("Attachment \(Log.hashIdentifier(attachmentId)) failed; the client's retries were the only ones", category: .attachment)
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
            let writeAttachmentData = self.writeAttachmentData
            let storeAttachmentClone = self.storeAttachmentClone
            guard let task = startDownloadOperation({ [weak self] recoveryGeneration in
                let foundNoRoom = RecoveryRoomFlag()
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
                    },
                    writeData: writeAttachmentData,
                    storeClone: storeAttachmentClone,
                    requestedFoundNoRoom: { foundNoRoom.set() }
                )
                // A recovery the floor admitted whose write then found no room shows the refusal
                // too, or the row would stay `queued` with nothing to tap.
                if foundNoRoom.isSet, !recoveryGeneration.isCancelled {
                    self?.recordSpaceRefusal(messageId: messageId, attachmentId: requestedAttachmentId)
                }
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
        // A row with no id names no Gmail attachment to retry.
        guard let message = attachment.message, let attachmentId = attachment.id else { return }
        let attachmentObjectID = attachment.objectID
        // Asked before the row is touched: a Retry the floor refuses leaves a failed row failed,
        // with its Retry, never `queued` with nothing to tap.
        guard await admitsByFreeSpace(attachment, messageId: message.id, attachmentId: attachmentId),
              isActive(generation) else {
            return
        }

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
        // Asked before the row is touched: the redownload path below writes `queued` over a
        // `downloaded` row, which a refusal must not leave behind.
        if let attachmentId = attachment.id {
            guard await admitsByFreeSpace(attachment, messageId: message.id, attachmentId: attachmentId),
                  isActive(generation) else {
                return
            }
        }

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
    
    /// Whether the floor admits downloading `attachment` (`hasRoomToDownload`). An attachment the
    /// user added is never downloaded, so it is never asked about.
    private func admitsByFreeSpace(
        _ attachment: Attachment,
        messageId: String,
        attachmentId: String
    ) async -> Bool {
        if attachmentId.hasPrefix("local_"), !attachmentId.hasPrefix("local_inline_") {
            return true
        }
        return await hasRoomToDownload(
            byteSize: attachment.byteSize,
            messageId: messageId,
            attachmentId: attachmentId
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
        #if os(macOS)
        // Outside the App Sandbox this sweep would delete files in the shared
        // ~/Library/Application Support/{Attachments,Previews}
        // (docs/mac-app-plan.md, PR C).
        guard SandboxTripwire.permitsDestructiveCleanup(.orphanedAttachmentFileSweep) else {
            return
        }
        #endif
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
        // Keep leases observed during this sweep alive through its stale
        // database snapshot, including files handed to a message after it.
        let cleanupLease = ComposeAttachmentLeaseRegistry.shared.beginFileCleanup()
        defer { ComposeAttachmentLeaseRegistry.shared.endFileCleanup(cleanupLease) }

        // Taken before the snapshot: anything written after this instant
        // (and within the grace period before it) may belong to a row the
        // snapshot cannot see yet.
        let snapshotStartedAt = Date()
        let recentFileCutoff = snapshotStartedAt.addingTimeInterval(-Self.orphanSweepRecentFileGracePeriod)
        let fetchAttachmentFileReferences = self.fetchAttachmentFileReferences
        let context = coreDataStack.newBackgroundContext()
        let validFiles: Set<String>? = await context.perform {
            do {
                // Outside the injectable fetch: with no store attached the
                // fetch answers [] and every file would be an orphan.
                try CoreDataStack.requireAttachedStore(in: context)
                let references = try fetchAttachmentFileReferences(context)
                return Set(references.flatMap { reference -> [String] in
                    [reference["localURL"] as? String, reference["previewURL"] as? String].compactMap { $0 }
                })
            } catch {
                // A failed read is never "no attachments": treating it as an
                // empty set deleted every attachment and preview on disk,
                // including the user's sent originals, which cannot be
                // re-downloaded. Skip, as the HTML orphan sweep does.
                Log.error("Skipping orphaned attachment cleanup because attachment paths could not be read", category: .attachment, error: error)
                return nil
            }
        }

        guard let validFiles else { return }
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
                if let path = relativePath, !validFiles.contains(path),
                   Self.isOldEnoughToSweep(fileURL, cutoff: recentFileCutoff) {
                    guard !generation.isCancelled else { return }
                    Self.removeOrphanedFile(at: fileURL, relativePath: path)
                } else if let path = relativePath {
                    Self.leaveOutOfBackupsIfDownloaded(fileURL, relativePath: path)
                }
            }

            guard !Task.isCancelled, !generation.isCancelled else { return }
            // Clean previews folder
            let previewsURL = appSupportURL.appendingPathComponent("Previews")
            let previewContents = FileSystemErrorHandler.contentsOfDirectory(at: previewsURL, category: .attachment)
            for fileURL in previewContents {
                guard !Task.isCancelled, !generation.isCancelled else { return }
                let relativePath = AttachmentPaths.relativePath(from: fileURL)
                if let path = relativePath, !validFiles.contains(path),
                   Self.isOldEnoughToSweep(fileURL, cutoff: recentFileCutoff) {
                    guard !generation.isCancelled else { return }
                    Self.removeOrphanedFile(at: fileURL, relativePath: path)
                }
            }
        }
        await withTaskCancellationHandler {
            await cleanupTask.value
        } onCancel: {
            cleanupTask.cancel()
        }
    }

    /// True only when both the file's creation and modification dates are
    /// readable and before `cutoff`. An unreadable date fails closed: the
    /// file is kept for a later sweep.
    nonisolated static func isOldEnoughToSweep(_ url: URL, cutoff: Date) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]),
              let created = values.creationDate,
              let modified = values.contentModificationDate else {
            return false
        }
        return max(created, modified) < cutoff
    }

    /// Marks a downloaded attachment that this sweep keeps as left out of backups, where it
    /// has no mark. A download is marked when it is written (`AttachmentPaths.saveData`);
    /// this is for the files a build from before the mark downloaded, which are most of
    /// what an existing installation has in `Attachments`. It only ever adds the mark: an
    /// original the user added to a message is never one of these
    /// (`AttachmentPaths.isRedownloadable`).
    nonisolated static func leaveOutOfBackupsIfDownloaded(_ url: URL, relativePath: String) {
        guard AttachmentPaths.isRedownloadable(relativePath),
              !BackupExclusion.isExcluded(url) else {
            return
        }
        BackupExclusion.exclude(url, category: .attachment)
    }

    /// Unsaved draft rows are invisible to the background-context snapshot.
    /// Consult the live lease under the same lock as file deletion.
    nonisolated static func removeOrphanedFile(
        at url: URL,
        relativePath: String,
        leases: ComposeAttachmentLeaseRegistry = .shared
    ) {
        leases.withProtectedResources { resources in
            guard !resources.filePaths.contains(relativePath) else { return }
            FileSystemErrorHandler.removeItem(at: url, category: .attachment)
        }
    }
}
