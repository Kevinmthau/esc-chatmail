import Foundation

/// Service for recovering HTML content from Gmail API when local files are missing
actor HTMLContentRecoveryService {
    static let shared = HTMLContentRecoveryService()

    private var recoveringMessageIds: Set<String> = []

    private init() {}

    /// Recovers HTML content for a message by fetching from Gmail API
    /// Returns the HTML content if successful, nil otherwise
    func recoverHTMLContent(messageId: String) async -> String? {
        // Prevent duplicate recovery attempts
        guard !recoveringMessageIds.contains(messageId) else { return nil }
        recoveringMessageIds.insert(messageId)
        defer { recoveringMessageIds.remove(messageId) }

        do {
            // 1. Fetch full message from Gmail API
            let apiClient = await MainActor.run { GmailAPIClient.shared }
            let gmailMessage = try await apiClient.getMessage(id: messageId, format: "full")

            // 2. Extract HTML body from MIME structure
            guard let payload = gmailMessage.payload,
                  let html = extractHTMLBody(from: payload) else {
                Log.debug("No HTML body found for message \(messageId)", category: .ui)
                return nil
            }

            // 3. Save to disk for future use
            let handler = HTMLContentHandler.shared
            _ = handler.saveHTML(html, for: messageId)

            Log.info("Recovered HTML content for message \(messageId)", category: .ui)
            return html
        } catch {
            Log.warning("Failed to recover HTML for \(messageId): \(error)", category: .ui)
            return nil
        }
    }

    /// Extracts HTML body from MIME structure
    private func extractHTMLBody(from part: MessagePart) -> String? {
        // Check this part for text/html
        if part.mimeType == "text/html", let data = part.body?.data {
            return decodeBase64(data)
        }

        // Recursively check child parts
        if let parts = part.parts {
            for subpart in parts {
                if let html = extractHTMLBody(from: subpart) {
                    return html
                }
            }
        }

        return nil
    }

    /// Decodes Gmail's URL-safe Base64 encoding
    private func decodeBase64(_ data: String) -> String? {
        let base64String = data
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        var paddedBase64 = base64String
        let remainder = base64String.count % 4
        if remainder > 0 {
            paddedBase64 = base64String + String(repeating: "=", count: 4 - remainder)
        }

        guard let decodedData = Data(base64Encoded: paddedBase64) else {
            return nil
        }

        return String(data: decodedData, encoding: .utf8)
    }
}
