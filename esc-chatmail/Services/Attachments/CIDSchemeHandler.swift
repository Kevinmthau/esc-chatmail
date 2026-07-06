import Foundation
import CoreData
import WebKit

/// Handles cid: (Content-ID) URL scheme for inline email attachments.
/// Resolves cid: URLs to the actual attachment data stored on disk.
///
/// cid: URLs in emails reference inline attachments by their Content-ID header.
/// For example: <img src="cid:image001@domain.com"> references an attachment
/// with Content-ID header: <image001@domain.com>
final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {

    /// The message containing the attachments to resolve
    weak var message: Message? {
        didSet {
            messageReference.update(message)
        }
    }

    /// Background context factory for persisting on-demand fallback data
    private let makeBackgroundContext: @Sendable () -> NSManagedObjectContext
    private let apiClientOverride: (any GmailAPIClientProtocol)?
    private let messageReference: MessageReference
    private let activeTasks = ActiveSchemeTaskRegistry()
    private let fetchCoalescer = CIDAttachmentFetchCoalescer()

    init(
        message: Message?,
        coreDataStack: CoreDataStack = .shared,
        apiClient: (any GmailAPIClientProtocol)? = nil,
        makeBackgroundContext: (@Sendable () -> NSManagedObjectContext)? = nil
    ) {
        self.messageReference = MessageReference(message: message)
        self.message = message
        self.makeBackgroundContext = makeBackgroundContext ?? {
            coreDataStack.newBackgroundContext()
        }
        self.apiClientOverride = apiClient
        super.init()
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = activeTasks.register(urlSchemeTask)

        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, taskID: taskID, with: URLError(.badURL))
            return
        }

        // Extract Content-ID from URL
        // cid:image001@domain.com -> image001@domain.com
        guard let contentId = Self.normalizedContentID(from: url) else {
            Log.debug("CIDSchemeHandler: Empty Content-ID from URL: \(url)", category: .ui)
            fail(urlSchemeTask, taskID: taskID, with: URLError(.badURL))
            return
        }

        let operation = Task { [weak self] in
            guard let self else { return }
            await self.handleRequest(
                urlSchemeTask,
                taskID: taskID,
                contentId: contentId
            )
        }

        activeTasks.setOperation(operation, for: taskID)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        activeTasks.cancel(urlSchemeTask)
    }

    // MARK: - Private Helpers

    private func handleRequest(
        _ urlSchemeTask: WKURLSchemeTask,
        taskID: ObjectIdentifier,
        contentId: String
    ) async {
        defer {
            activeTasks.finish(taskID)
        }

        guard activeTasks.isActive(taskID) else {
            return
        }

        guard let attachment = await attachmentSnapshot(withContentId: contentId) else {
            guard activeTasks.isActive(taskID) else { return }
            Log.debug("CIDSchemeHandler: No attachment found for Content-ID: \(contentId)", category: .ui)
            // Return a transparent pixel instead of failing, to avoid broken image icons
            respondWithTransparentPixel(urlSchemeTask, taskID: taskID)
            return
        }

        guard activeTasks.isActive(taskID) else {
            return
        }

        // Load attachment data from disk first.
        if let localPath = attachment.localURL,
           let data = AttachmentPaths.loadData(from: localPath) {
            guard activeTasks.isActive(taskID) else { return }
            Log.debug("CIDSchemeHandler: eager/local hit for Content-ID: \(contentId)", category: .ui)
            respond(urlSchemeTask, taskID: taskID, with: data, mimeType: attachment.mimeType)
            return
        }

        Log.debug("CIDSchemeHandler: on-demand fallback fetch for Content-ID: \(contentId)", category: .ui)
        if let data = await fetchAndPersistMissingAttachmentData(
            attachment: attachment,
            requestedContentId: contentId
        ) {
            guard activeTasks.isActive(taskID) else { return }
            respond(urlSchemeTask, taskID: taskID, with: data, mimeType: attachment.mimeType)
        } else {
            guard activeTasks.isActive(taskID) else { return }
            Log.debug("CIDSchemeHandler: Attachment not downloaded for Content-ID: \(contentId)", category: .ui)
            respondWithTransparentPixel(urlSchemeTask, taskID: taskID)
        }
    }

    /// Extracts the Content-ID from a cid: URL
    static func normalizedContentID(from url: URL) -> String? {
        // cid: URLs can be formatted as:
        // - cid:image001@domain.com
        // - cid://image001@domain.com
        // - cid:///image001@domain.com
        // We need to handle all variants

        var contentId = url.absoluteString

        // Remove cid: prefix
        if contentId.lowercased().hasPrefix("cid:") {
            contentId = String(contentId.dropFirst(4))
        }

        return EmailDocument.normalizedContentID(contentId)
    }

    private func attachmentSnapshot(withContentId contentId: String) async -> AttachmentSnapshot? {
        guard let messageObjectID = messageReference.currentObjectID() else {
            return nil
        }

        let context = makeBackgroundContext()
        return await context.perform {
            guard let message = try? context.existingObject(with: messageObjectID) as? Message else {
                return nil
            }

            return Self.findAttachmentSnapshot(withContentId: contentId, in: message)
        }
    }

    /// Finds an attachment in the message with the given Content-ID.
    /// Must be called from the message's managed object context queue.
    private static func findAttachmentSnapshot(withContentId contentId: String, in message: Message) -> AttachmentSnapshot? {
        guard let attachments = message.attachments else {
            return nil
        }

        if let attachment = attachments.first(where: {
            EmailDocument.normalizedContentID($0.contentId) == contentId
        }) {
            return AttachmentSnapshot(message: message, attachment: attachment)
        }

        let contentIdWithoutDomain = contentId.components(separatedBy: "@").first ?? contentId
        if let attachment = attachments.first(where: {
            guard let attachmentContentId = EmailDocument.normalizedContentID($0.contentId) else { return false }
            let attachmentIdWithoutDomain = attachmentContentId.components(separatedBy: "@").first ?? attachmentContentId
            return attachmentIdWithoutDomain == contentIdWithoutDomain
        }) {
            return AttachmentSnapshot(message: message, attachment: attachment)
        }

        return nil
    }

    private func fetchAndPersistMissingAttachmentData(
        attachment: AttachmentSnapshot,
        requestedContentId: String
    ) async -> Data? {
        guard let attachmentId = attachment.attachmentId,
              !attachmentId.isEmpty,
              !attachmentId.hasPrefix("local_") else {
            return nil
        }

        let key = CIDAttachmentFetchKey(
            messageId: attachment.messageId,
            attachmentId: attachmentId,
            normalizedContentID: attachment.normalizedContentID ?? requestedContentId
        )

        return await fetchCoalescer.data(for: key) { [apiClientOverride, makeBackgroundContext] in
            await Self.fetchAndPersistMissingAttachmentData(
                messageId: attachment.messageId,
                attachmentId: attachmentId,
                mimeType: attachment.mimeType,
                filename: attachment.filename,
                attachmentObjectID: attachment.objectID,
                apiClientOverride: apiClientOverride,
                makeBackgroundContext: makeBackgroundContext
            )
        }
    }

    private static func fetchAndPersistMissingAttachmentData(
        messageId: String,
        attachmentId: String,
        mimeType: String,
        filename: String,
        attachmentObjectID: NSManagedObjectID,
        apiClientOverride: (any GmailAPIClientProtocol)?,
        makeBackgroundContext: @Sendable () -> NSManagedObjectContext
    ) async -> Data? {
        do {
            let apiClient: any GmailAPIClientProtocol
            if let apiClientOverride {
                apiClient = apiClientOverride
            } else {
                apiClient = await MainActor.run { GmailAPIClient.shared }
            }

            let data = try await apiClient.getAttachment(messageId: messageId, attachmentId: attachmentId)
            AttachmentPaths.setupDirectories()

            let filenameExt = (filename as NSString).pathExtension.lowercased()
            let ext = filenameExt.isEmpty ? AttachmentPaths.fileExtension(for: mimeType) : filenameExt
            let originalPath = AttachmentPaths.originalPath(idOrUUID: attachmentId, ext: ext)

            guard AttachmentPaths.saveData(data, to: originalPath) else {
                return data
            }

            let backgroundContext = makeBackgroundContext()
            await backgroundContext.perform {
                guard let attachment = try? backgroundContext.existingObject(with: attachmentObjectID) as? Attachment else {
                    return
                }

                attachment.localURL = originalPath
                attachment.byteSize = Int64(max(Int(attachment.byteSize), data.count))
                attachment.state = .downloaded
                attachment.lastDownloadFailedAt = nil
                backgroundContext.saveOrLog(operation: "persist inline cid attachment")
            }

            return data
        } catch {
            await markAttachmentDownloadFailed(
                attachmentObjectID: attachmentObjectID,
                makeBackgroundContext: makeBackgroundContext
            )
            Log.debug("CIDSchemeHandler: On-demand fetch failed for attachment \(attachmentId): \(error.localizedDescription)", category: .ui)
            return nil
        }
    }

    private static func markAttachmentDownloadFailed(
        attachmentObjectID: NSManagedObjectID,
        makeBackgroundContext: @Sendable () -> NSManagedObjectContext
    ) async {
        let backgroundContext = makeBackgroundContext()
        await backgroundContext.perform {
            guard let attachment = try? backgroundContext.existingObject(with: attachmentObjectID) as? Attachment else {
                return
            }

            attachment.state = .failed
            attachment.lastDownloadFailedAt = Date()
            backgroundContext.saveOrLog(operation: "mark inline cid attachment failed", category: .attachment)
        }
    }

    private func respond(_ urlSchemeTask: WKURLSchemeTask, taskID: ObjectIdentifier, with data: Data, mimeType: String) {
        guard activeTasks.isActive(taskID) else { return }

        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, taskID: taskID, with: URLError(.badURL))
            return
        }

        let resolvedMimeType = mimeType.isEmpty ? "application/octet-stream" : mimeType
        let response = URLResponse(
            url: url,
            mimeType: resolvedMimeType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )

        guard activeTasks.isActive(taskID) else { return }
        urlSchemeTask.didReceive(response)
        guard activeTasks.isActive(taskID) else { return }
        urlSchemeTask.didReceive(data)
        guard activeTasks.isActive(taskID) else { return }
        urlSchemeTask.didFinish()
    }

    /// Responds with a transparent 1x1 GIF pixel for missing attachments
    private func respondWithTransparentPixel(_ urlSchemeTask: WKURLSchemeTask, taskID: ObjectIdentifier) {
        guard activeTasks.isActive(taskID) else { return }

        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, taskID: taskID, with: URLError(.badURL))
            return
        }

        // Transparent 1x1 GIF
        let transparentPixelBase64 = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
        guard let data = Data(base64Encoded: transparentPixelBase64) else {
            fail(urlSchemeTask, taskID: taskID, with: URLError(.cannotDecodeRawData))
            return
        }

        let response = URLResponse(
            url: url,
            mimeType: "image/gif",
            expectedContentLength: data.count,
            textEncodingName: nil
        )

        guard activeTasks.isActive(taskID) else { return }
        urlSchemeTask.didReceive(response)
        guard activeTasks.isActive(taskID) else { return }
        urlSchemeTask.didReceive(data)
        guard activeTasks.isActive(taskID) else { return }
        urlSchemeTask.didFinish()
    }

    private func fail(_ urlSchemeTask: WKURLSchemeTask, taskID: ObjectIdentifier, with error: Error) {
        defer {
            activeTasks.finish(taskID)
        }

        guard activeTasks.isActive(taskID) else { return }
        urlSchemeTask.didFailWithError(error)
    }
}

private struct AttachmentSnapshot: @unchecked Sendable {
    let messageId: String
    let attachmentId: String?
    let normalizedContentID: String?
    let mimeType: String
    let filename: String
    let localURL: String?
    let objectID: NSManagedObjectID

    init(message: Message, attachment: Attachment) {
        self.messageId = message.id
        self.attachmentId = attachment.id
        self.normalizedContentID = EmailDocument.normalizedContentID(attachment.contentId)
        self.mimeType = attachment.mimeType
        self.filename = attachment.filename
        self.localURL = attachment.localURL
        self.objectID = attachment.objectID
    }
}

private struct CIDAttachmentFetchKey: Hashable, Sendable {
    let messageId: String
    let attachmentId: String
    let normalizedContentID: String
}

private actor CIDAttachmentFetchCoalescer {
    private var inFlight: [CIDAttachmentFetchKey: Task<Data?, Never>] = [:]

    func data(
        for key: CIDAttachmentFetchKey,
        operation: @escaping @Sendable () async -> Data?
    ) async -> Data? {
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task {
            await operation()
        }
        inFlight[key] = task

        let data = await task.value
        inFlight[key] = nil
        return data
    }
}

private final class MessageReference {
    private let lock = NSLock()
    private var messageObjectID: NSManagedObjectID?

    init(message: Message?) {
        self.messageObjectID = message?.objectID
    }

    func update(_ message: Message?) {
        lock.lock()
        messageObjectID = message?.objectID
        lock.unlock()
    }

    func currentObjectID() -> NSManagedObjectID? {
        lock.lock()
        defer { lock.unlock() }
        return messageObjectID
    }
}

private final class ActiveSchemeTaskRegistry {
    private struct Entry {
        var operation: Task<Void, Never>?
        var isCancelled = false
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(_ urlSchemeTask: WKURLSchemeTask) -> ObjectIdentifier {
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.lock()
        entries[id] = Entry()
        lock.unlock()
        return id
    }

    func setOperation(_ operation: Task<Void, Never>, for id: ObjectIdentifier) {
        lock.lock()
        guard var entry = entries[id] else {
            lock.unlock()
            operation.cancel()
            return
        }

        guard !entry.isCancelled else {
            entries.removeValue(forKey: id)
            lock.unlock()
            operation.cancel()
            return
        }

        entry.operation = operation
        entries[id] = entry
        lock.unlock()
    }

    func cancel(_ urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.lock()
        guard var entry = entries[id] else {
            lock.unlock()
            return
        }

        entry.isCancelled = true
        let operation = entry.operation
        entries[id] = entry
        lock.unlock()

        operation?.cancel()
    }

    func isActive(_ id: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[id] else {
            return false
        }

        return !entry.isCancelled
    }

    func finish(_ id: ObjectIdentifier) {
        lock.lock()
        entries.removeValue(forKey: id)
        lock.unlock()
    }
}
