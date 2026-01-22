import Foundation

// MARK: - Attachments API

extension GmailAPIClient {

    /// Fetches attachment data for a message.
    nonisolated func getAttachment(messageId: String, attachmentId: String) async throws -> Data {
        let response: AttachmentResponse = try await performGET(
            endpoint: APIEndpoints.attachment(messageId: messageId, attachmentId: attachmentId)
        )

        guard let attachmentData = Data(base64UrlEncoded: response.data) else {
            throw APIError.invalidData("Failed to decode attachment data from base64")
        }

        return attachmentData
    }
}
