import Foundation

// MARK: - Attachments API

extension GmailAPIClient {

    /// Fetches attachment data for a message.
    nonisolated func getAttachment(messageId: String, attachmentId: String) async throws -> Data {
        let endpoint = APIEndpoints.attachment(messageId: messageId, attachmentId: attachmentId)
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidURL(endpoint)
        }
        let request = try await authenticatedRequest(url: url)
        let response: AttachmentResponse = try await performRequestWithRetry(request)

        guard let attachmentData = Data(base64UrlEncoded: response.data) else {
            throw NSError(domain: "GmailAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode attachment data"])
        }

        return attachmentData
    }
}
