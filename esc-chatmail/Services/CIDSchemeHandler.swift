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
    weak var message: Message?

    /// Core Data stack for fetching attachment data
    private let coreDataStack: CoreDataStack
    private let apiClientOverride: (any GmailAPIClientProtocol)?

    init(
        message: Message?,
        coreDataStack: CoreDataStack = .shared,
        apiClient: (any GmailAPIClientProtocol)? = nil
    ) {
        self.message = message
        self.coreDataStack = coreDataStack
        self.apiClientOverride = apiClient
        super.init()
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Extract Content-ID from URL
        // cid:image001@domain.com -> image001@domain.com
        let contentId = extractContentId(from: url)

        guard !contentId.isEmpty else {
            Log.debug("CIDSchemeHandler: Empty Content-ID from URL: \(url)", category: .ui)
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Find attachment with matching Content-ID
        guard let message = message,
              let attachment = findAttachment(withContentId: contentId, in: message) else {
            Log.debug("CIDSchemeHandler: No attachment found for Content-ID: \(contentId)", category: .ui)
            // Return a transparent pixel instead of failing, to avoid broken image icons
            respondWithTransparentPixel(urlSchemeTask)
            return
        }

        // Load attachment data from disk first.
        if let localPath = attachment.localURL,
           let data = AttachmentPaths.loadData(from: localPath) {
            respond(urlSchemeTask, with: data, mimeType: attachment.mimeType)
            return
        }

        // On-demand fallback: fetch missing inline attachment bytes immediately so full email
        // view can render all cid: images without waiting for a background download sweep.
        let messageId = message.id
        let attachmentId = attachment.id
        let mimeType = attachment.mimeType
        let filename = attachment.filename
        let attachmentObjectID = attachment.objectID

        Task { [weak self] in
            guard let self else { return }
            if let data = await self.fetchAndPersistMissingAttachmentData(
                messageId: messageId,
                attachmentId: attachmentId,
                mimeType: mimeType,
                filename: filename,
                attachmentObjectID: attachmentObjectID
            ) {
                self.respond(urlSchemeTask, with: data, mimeType: mimeType)
            } else {
                Log.debug("CIDSchemeHandler: Attachment not downloaded for Content-ID: \(contentId)", category: .ui)
                self.respondWithTransparentPixel(urlSchemeTask)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // No per-task cleanup required.
    }

    // MARK: - Private Helpers

    /// Extracts the Content-ID from a cid: URL
    private func extractContentId(from url: URL) -> String {
        // cid: URLs can be formatted as:
        // - cid:image001@domain.com
        // - cid://image001@domain.com
        // - cid:///image001@domain.com
        // We need to handle all variants

        var contentId = url.absoluteString

        // Remove cid: prefix
        if contentId.hasPrefix("cid:") {
            contentId = String(contentId.dropFirst(4))
        }

        // Remove leading slashes (for cid:// format)
        while contentId.hasPrefix("/") {
            contentId = String(contentId.dropFirst())
        }

        // URL decode in case of encoded characters
        contentId = contentId.removingPercentEncoding ?? contentId

        // Trim whitespace
        contentId = contentId.trimmingCharacters(in: .whitespacesAndNewlines)

        return contentId
    }

    /// Finds an attachment in the message with the given Content-ID
    private func findAttachment(withContentId contentId: String, in message: Message) -> Attachment? {
        guard let attachments = message.attachments else {
            return nil
        }

        // Try exact match first
        if let attachment = attachments.first(where: { $0.contentId == contentId }) {
            return attachment
        }

        // Try case-insensitive match
        let lowercasedContentId = contentId.lowercased()
        if let attachment = attachments.first(where: { $0.contentId?.lowercased() == lowercasedContentId }) {
            return attachment
        }

        // Try matching without domain part (some email clients strip it)
        let contentIdWithoutDomain = contentId.components(separatedBy: "@").first ?? contentId
        if let attachment = attachments.first(where: {
            guard let attachmentContentId = $0.contentId else { return false }
            let attachmentIdWithoutDomain = attachmentContentId.components(separatedBy: "@").first ?? attachmentContentId
            return attachmentIdWithoutDomain.lowercased() == contentIdWithoutDomain.lowercased()
        }) {
            return attachment
        }

        return nil
    }

    private func fetchAndPersistMissingAttachmentData(
        messageId: String,
        attachmentId: String?,
        mimeType: String,
        filename: String,
        attachmentObjectID: NSManagedObjectID
    ) async -> Data? {
        guard let attachmentId,
              !attachmentId.isEmpty,
              !attachmentId.hasPrefix("local_") else {
            return nil
        }

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

            let backgroundContext = coreDataStack.newBackgroundContext()
            await backgroundContext.perform {
                guard let attachment = try? backgroundContext.existingObject(with: attachmentObjectID) as? Attachment else {
                    return
                }

                attachment.localURL = originalPath
                attachment.byteSize = Int64(max(Int(attachment.byteSize), data.count))
                attachment.state = .downloaded
                backgroundContext.saveOrLog(operation: "persist inline cid attachment")
            }

            return data
        } catch {
            Log.debug("CIDSchemeHandler: On-demand fetch failed for attachment \(attachmentId): \(error.localizedDescription)", category: .ui)
            return nil
        }
    }

    private func respond(_ urlSchemeTask: WKURLSchemeTask, with data: Data, mimeType: String) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let resolvedMimeType = mimeType.isEmpty ? "application/octet-stream" : mimeType
        let response = URLResponse(
            url: url,
            mimeType: resolvedMimeType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    /// Responds with a transparent 1x1 GIF pixel for missing attachments
    private func respondWithTransparentPixel(_ urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Transparent 1x1 GIF
        let transparentPixelBase64 = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
        guard let data = Data(base64Encoded: transparentPixelBase64) else {
            urlSchemeTask.didFailWithError(URLError(.cannotDecodeRawData))
            return
        }

        let response = URLResponse(
            url: url,
            mimeType: "image/gif",
            expectedContentLength: data.count,
            textEncodingName: nil
        )

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
}
