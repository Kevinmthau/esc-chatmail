import Foundation

/// Service for recovering HTML content from Gmail API when local files are missing
actor HTMLContentRecoveryService {
    static let shared = HTMLContentRecoveryService()

    private var recoveringMessageIds: Set<String> = []
    private var messagesKnownWithoutHTML: Set<String> = []

    private init() {}

    /// Recovers HTML content for a message by fetching from Gmail API
    /// Returns the HTML content if successful, nil otherwise
    func recoverHTMLContent(messageId: String) async -> String? {
        // Avoid repeated API calls for messages we already confirmed have no HTML part.
        guard !messagesKnownWithoutHTML.contains(messageId) else { return nil }

        // Prevent duplicate recovery attempts
        guard !recoveringMessageIds.contains(messageId) else { return nil }
        recoveringMessageIds.insert(messageId)
        defer { recoveringMessageIds.remove(messageId) }

        do {
            // 1. Fetch full message from Gmail API
            let apiClient = await MainActor.run { GmailAPIClient.shared }
            let gmailMessage = try await apiClient.getMessage(id: messageId, format: "full")

            // 2. Extract HTML body from MIME structure (may fetch large body parts via API)
            guard let payload = gmailMessage.payload,
                  let html = await extractHTMLBody(from: payload, messageId: messageId) else {
                if gmailMessage.payload != nil {
                    messagesKnownWithoutHTML.insert(messageId)
                }
                Log.debug("No HTML body found for message \(messageId)", category: .ui)
                return nil
            }

            // 3. Save to disk for future use
            let handler = HTMLContentHandler.shared
            _ = handler.saveHTML(html, for: messageId)

            messagesKnownWithoutHTML.remove(messageId)
            Log.info("Recovered HTML content for message \(messageId)", category: .ui)
            return html
        } catch {
            Log.warning("Failed to recover HTML for \(messageId): \(error)", category: .ui)
            return nil
        }
    }

    /// Extracts HTML body from MIME structure
    private func extractHTMLBody(from part: MessagePart, messageId: String) async -> String? {
        let resolvedMimeType = resolvedMimeType(for: part)

        // Check this part for text/html
        if isHTMLMimeType(resolvedMimeType) {
            if let data = part.body?.data {
                return decodeBody(data, headers: part.headers)
            } else if let attachmentId = part.body?.attachmentId {
                // Large HTML body - fetch via attachment API
                return await fetchLargeBodyContent(attachmentId: attachmentId, messageId: messageId, headers: part.headers)
            }
        }

        // Recursively check child parts
        if let parts = part.parts {
            for subpart in parts {
                if let html = await extractHTMLBody(from: subpart, messageId: messageId) {
                    return html
                }
            }
        }

        return nil
    }

    /// Fetches large body content via the attachment API
    /// Gmail returns body parts larger than ~25KB with attachmentId instead of inline data
    private func fetchLargeBodyContent(attachmentId: String, messageId: String, headers: [MessageHeader]?) async -> String? {
        do {
            let apiClient = await MainActor.run { GmailAPIClient.shared }
            let attachmentData = try await apiClient.getAttachment(messageId: messageId, attachmentId: attachmentId)
            let text = String(decoding: attachmentData, as: UTF8.self)
            return decodeTransferEncoding(text, headers: headers)
        } catch {
            Log.warning("Failed to fetch large body \(attachmentId) for message \(messageId): \(error)", category: .ui)
            return nil
        }
    }

    /// Decodes Gmail's URL-safe Base64 encoding
    private func decodeBody(_ data: String, headers: [MessageHeader]?) -> String? {
        guard let decodedData = decodeBase64Data(data) else {
            return nil
        }
        let text = String(decoding: decodedData, as: UTF8.self)
        return decodeTransferEncoding(text, headers: headers)
    }

    private func decodeBase64Data(_ data: String) -> Data? {
        // Gmail uses URL-safe base64 (RFC 4648) and may include incidental whitespace/newlines.
        // Be permissive here; decode failures would prevent HTML recovery and leave emails blank.
        let base64String = data
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: " ", with: "")

        var paddedBase64 = base64String
        let remainder = base64String.count % 4
        if remainder > 0 {
            paddedBase64 = base64String + String(repeating: "=", count: 4 - remainder)
        }

        guard let decodedData = Data(base64Encoded: paddedBase64, options: [.ignoreUnknownCharacters]) else {
            return nil
        }

        return decodedData
    }

    private func resolvedMimeType(for part: MessagePart) -> String? {
        if let directMimeType = part.mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !directMimeType.isEmpty {
            return directMimeType
        }

        guard let contentType = part.headers?
            .first(where: { $0.name.lowercased() == "content-type" })?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !contentType.isEmpty else {
            return nil
        }

        return contentType
    }

    private func isHTMLMimeType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !mimeType.isEmpty else {
            return false
        }

        return mimeType.hasPrefix("text/html")
    }

    private func decodeTransferEncoding(_ text: String, headers: [MessageHeader]?) -> String {
        let encoding = headers?.first { $0.name.lowercased() == "content-transfer-encoding" }?.value.lowercased()
        if encoding?.contains("quoted-printable") == true {
            return QuotedPrintableDecoder.decode(text)
        }
        if encoding == nil, looksQuotedPrintable(text) {
            return QuotedPrintableDecoder.decode(text)
        }
        return text
    }

    private func looksQuotedPrintable(_ text: String) -> Bool {
        if text.contains("=\r\n") || text.contains("=\n") {
            return true
        }
        let lower = text.lowercased()
        if lower.contains("=3d") || lower.contains("=3c") || lower.contains("=3e") {
            return true
        }
        return false
    }
}
