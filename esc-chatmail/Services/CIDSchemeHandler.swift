import Foundation
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

    init(message: Message?, coreDataStack: CoreDataStack = .shared) {
        self.message = message
        self.coreDataStack = coreDataStack
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

        // Load attachment data from disk
        guard let localPath = attachment.localURL,
              let data = AttachmentPaths.loadData(from: localPath) else {
            // Attachment exists but not downloaded yet - return transparent pixel
            Log.debug("CIDSchemeHandler: Attachment not downloaded for Content-ID: \(contentId)", category: .ui)
            respondWithTransparentPixel(urlSchemeTask)
            return
        }

        // Create response with correct MIME type
        let mimeType = attachment.mimeType.isEmpty ? "application/octet-stream" : attachment.mimeType
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // No cleanup needed - we complete synchronously
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
