import Foundation
import CoreData
import Combine

struct ForwardAttachmentSnapshot: Equatable {
    let filename: String
    let mimeType: String
    let byteSize: Int64
    let localURL: String?
    let previewURL: String?
    let width: Int16
    let height: Int16
    let pageCount: Int16
}

/// Protects unsaved compose files and rows from maintenance until discard or send handoff.
/// Cleanup executes its synchronous delete while holding the same lock as registration.
final class ComposeAttachmentLeaseRegistry: @unchecked Sendable {
    static let shared = ComposeAttachmentLeaseRegistry()

    struct Resources {
        let attachmentIDs: Set<String>
        let filePaths: Set<String>
    }

    private let lock = NSLock()
    private var sessions: [UUID: [String: Set<String>]] = [:]
    private var fileCleanupSnapshots: [UUID: Set<String>] = [:]

    func protect(sessionID: UUID, attachmentID: String, filePaths: Set<String>) {
        lock.withLock {
            sessions[sessionID, default: [:]][attachmentID] = filePaths
            for cleanupID in Array(fileCleanupSnapshots.keys) {
                fileCleanupSnapshots[cleanupID, default: []].formUnion(filePaths)
            }
        }
    }

    func remove(sessionID: UUID, attachmentID: String) {
        lock.withLock {
            sessions[sessionID]?[attachmentID] = nil
            if sessions[sessionID]?.isEmpty == true { sessions[sessionID] = nil }
        }
    }

    func release(sessionID: UUID) {
        _ = lock.withLock { sessions.removeValue(forKey: sessionID) }
    }

    /// A sweep may have read persisted paths before a draft was saved and handed off.
    /// Retain every path leased during the sweep until its stale snapshot is retired.
    func beginFileCleanup() -> UUID {
        lock.withLock {
            let cleanupID = UUID()
            fileCleanupSnapshots[cleanupID] = Set(sessions.values.flatMap { $0.values }.flatMap { $0 })
            return cleanupID
        }
    }

    func endFileCleanup(_ cleanupID: UUID) {
        _ = lock.withLock { fileCleanupSnapshots.removeValue(forKey: cleanupID) }
    }

    func withProtectedResources<T>(_ body: (Resources) throws -> T) rethrows -> T {
        try lock.withLock {
            let attachments = sessions.values.flatMap { $0 }
            return try body(Resources(
                attachmentIDs: Set(attachments.map(\.key)),
                filePaths: Set(attachments.flatMap(\.value)).union(fileCleanupSnapshots.values.flatMap { $0 })
            ))
        }
    }
}

/// Handles attachment lifecycle including cleanup of local files
@MainActor
final class ComposeAttachmentManager: ObservableObject {
    @Published var attachments: [Attachment] = []
    private(set) var inlineAttachments: [Attachment] = []
    @Published private(set) var isImportingAttachments = false

    private let viewContext: NSManagedObjectContext
    private var activeImportIDs: Set<UUID> = []
    private let sessionID = UUID()
    private let leaseRegistry: ComposeAttachmentLeaseRegistry

    init(
        viewContext: NSManagedObjectContext = CoreDataStack.shared.viewContext,
        leaseRegistry: ComposeAttachmentLeaseRegistry = .shared
    ) {
        self.viewContext = viewContext
        self.leaseRegistry = leaseRegistry
    }

    deinit {
        leaseRegistry.release(sessionID: sessionID)
    }

    func addAttachment(_ attachment: Attachment) {
        attachments.append(attachment)
    }

    func setImportInProgress(_ isInProgress: Bool, id: UUID) {
        if isInProgress {
            activeImportIDs.insert(id)
        } else {
            activeImportIDs.remove(id)
        }

        let hasActiveImports = !activeImportIDs.isEmpty
        if isImportingAttachments != hasActiveImports {
            isImportingAttachments = hasActiveImports
        }
    }

    func removeAttachment(_ attachment: Attachment) {
        guard let index = attachments.firstIndex(of: attachment) else { return }
        let removed = attachments.remove(at: index)
        deleteDraftAttachment(removed)
    }

    func clear() {
        for attachment in attachments + inlineAttachments { deleteDraftAttachment(attachment) }
        attachments.removeAll()
        inlineAttachments.removeAll()
        leaseRegistry.release(sessionID: sessionID)
    }

    /// The optimistic message now owns these entities and files.
    func relinquishAttachmentsAfterSend() {
        attachments.removeAll()
        inlineAttachments.removeAll()
        leaseRegistry.release(sessionID: sessionID)
    }

    func copyInlineAttachmentsForForward(_ infos: [GmailSendService.AttachmentInfo]) throws {
        for info in infos {
            guard let contentID = info.contentId, !contentID.isEmpty,
                  let copied = copyAttachmentForForward(.init(
                    filename: info.filename,
                    mimeType: info.mimeType,
                    byteSize: 0,
                    localURL: info.localURL,
                    previewURL: nil,
                    width: 0,
                    height: 0,
                    pageCount: 0
                  )) else {
                throw OutboundAttachmentContextBuilder.BuildError.attachmentNotReady(filename: info.filename)
            }
            copied.contentId = contentID
            inlineAttachments.append(copied)
        }
    }

    /// Recovery edits use copies, keeping the definitely unsent message intact until admission.
    func copyRecoveredAttachments(_ references: [LocalAttachmentReference]) throws {
        for reference in references {
            guard let objectID = reference.resolveObjectID(in: viewContext),
                  let original = try? viewContext.existingObject(with: objectID) as? Attachment,
                  !original.isDeleted else {
                throw OutboundAttachmentContextBuilder.BuildError.attachmentNotReady(filename: "Recovered attachment")
            }
            if let contentID = original.contentId, !contentID.isEmpty {
                try copyInlineAttachmentsForForward([.init(
                    localURL: original.readableLocalURLValue,
                    filename: original.filenameValue,
                    mimeType: original.mimeTypeValue,
                    contentId: contentID
                )])
            } else {
                guard let copied = copyAttachmentForForward(.init(
                    filename: original.filenameValue,
                    mimeType: original.mimeTypeValue,
                    byteSize: original.byteSize,
                    localURL: original.readableLocalURLValue,
                    previewURL: original.readablePreviewURLValue,
                    width: original.width,
                    height: original.height,
                    pageCount: original.pageCount
                )) else {
                    throw OutboundAttachmentContextBuilder.BuildError.attachmentNotReady(filename: original.filenameValue)
                }
                addAttachment(copied)
            }
        }
    }

    private func deleteDraftAttachment(_ attachment: Attachment) {
        guard !attachment.isDeleted,
              attachment.managedObjectContext === viewContext,
              attachment.message == nil,
              attachment.replyDraft == nil else { return }
        if let attachmentID = attachment.attachmentId, attachmentID.hasPrefix("local_") {
            AttachmentPaths.deleteFile(at: attachment.localURLValue)
            AttachmentPaths.deleteFile(at: attachment.previewURLValue)
            leaseRegistry.remove(sessionID: sessionID, attachmentID: attachmentID)
        }
        viewContext.delete(attachment)
    }

    /// Copies a forwarded attachment into local draft state.
    /// Returns nil if the attachment data is not available (for example not downloaded).
    func copyAttachmentForForward(_ snapshot: ForwardAttachmentSnapshot) -> Attachment? {
        guard let originalURL = AttachmentPaths.fullURL(for: snapshot.localURL),
              FileManager.default.isReadableFile(atPath: originalURL.path) else {
            Log.warning("Cannot copy attachment for forward: not downloaded", category: .attachment)
            return nil
        }

        // Generate new local ID and paths
        let newId = "local_\(UUID().uuidString)"
        let ext = AttachmentPaths.fileExtension(for: snapshot.mimeType)
        let newPath = AttachmentPaths.originalPath(idOrUUID: newId, ext: ext)
        let previewPath = AttachmentPaths.previewPath(idOrUUID: newId)
        leaseRegistry.protect(
            sessionID: sessionID,
            attachmentID: newId,
            filePaths: [newPath, previewPath]
        )

        do {
            guard let destinationURL = AttachmentPaths.fullURL(for: newPath) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: originalURL, to: destinationURL)
        } catch {
            AttachmentPaths.deleteFile(at: newPath)
            leaseRegistry.remove(sessionID: sessionID, attachmentID: newId)
            Log.error("Failed to save copied attachment for forward", category: .attachment)
            return nil
        }

        // Copy preview if available
        var newPreviewPath: String?
        if let originalPreviewURL = AttachmentPaths.fullURL(for: snapshot.previewURL),
           let previewURL = AttachmentPaths.fullURL(for: previewPath) {
            do {
                try FileManager.default.createDirectory(at: previewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: originalPreviewURL, to: previewURL)
                newPreviewPath = previewPath
            } catch {
                AttachmentPaths.deleteFile(at: previewPath)
            }
        }

        // Create new attachment entity
        let newAttachment = Attachment(context: viewContext)
        newAttachment.setValue(newId, forKey: "id")
        newAttachment.setValue(snapshot.filename, forKey: "filename")
        newAttachment.setValue(snapshot.mimeType, forKey: "mimeType")
        let actualByteSize = (try? originalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
        newAttachment.setValue(actualByteSize ?? snapshot.byteSize, forKey: "byteSize")
        newAttachment.setValue(newPath, forKey: "localURL")
        newAttachment.setValue(newPreviewPath, forKey: "previewURL")
        newAttachment.setValue("queued", forKey: "stateRaw")
        newAttachment.setValue(snapshot.width, forKey: "width")
        newAttachment.setValue(snapshot.height, forKey: "height")
        newAttachment.setValue(snapshot.pageCount, forKey: "pageCount")

        return newAttachment
    }
}
