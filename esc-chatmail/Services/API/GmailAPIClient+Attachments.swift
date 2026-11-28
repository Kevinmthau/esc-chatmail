import Foundation

// MARK: - Attachments API

extension GmailAPIClient {

    /// Fetches attachment data for a message, whole, on the read session. Sync's body parts and
    /// the HTML and CID recoveries use this: their verdicts are built on its errors and on the
    /// read session's limits. The downloader of a received attachment uses
    /// `downloadAttachmentFile` instead.
    nonisolated func getAttachment(messageId: String, attachmentId: String) async throws -> Data {
        let response: AttachmentResponse = try await performGET(
            endpoint: APIEndpoints.attachment(messageId: messageId, attachmentId: attachmentId)
        )

        guard let attachmentData = Data(base64UrlEncoded: response.data) else {
            throw APIError.invalidData("Failed to decode attachment data from base64")
        }

        return attachmentData
    }

    /// Downloads an attachment's bytes to a new file in `directory` and returns its URL. Only the
    /// downloader of a received attachment calls this (`AttachmentDownloader`), which moves the
    /// file into place and owns it from then on.
    ///
    /// The response, the attachment in base64url inside JSON, about 1.37 times its size, goes to
    /// disk as it arrives, on `transferSession` (a long whole-transfer cap and no connectivity
    /// wait), through the same retry engine as every read: the 401 refresh, the 429 pacing,
    /// `classify403` and the time-budget breaker. It is then decoded into the returned file a
    /// chunk at a time (`GmailAttachmentBodyDecoder`). `getAttachment` held the whole response
    /// and made about four copies of it in memory, under the read session's 60 s cap
    /// (architecture review 2026-11, attachments-storage-disk#2, networking#2).
    ///
    /// Both files are staged in `directory`, which the caller passes as `Attachments`, never the
    /// temporary directory: a sign-out drains every download before it removes `Attachments`,
    /// and the orphan sweep removes what a killed process left there. Their names start with
    /// `incoming_`, never `remote_` or `local_`, so no reader takes them for an attachment. The
    /// response file is removed before this returns or throws; the returned file is the
    /// caller's. A body whose `data` cannot be decoded is `APIError.invalidData`, with nothing
    /// kept; an error writing either file (a full disk) is thrown as it is, for the caller to
    /// classify.
    nonisolated func downloadAttachmentFile(
        messageId: String,
        attachmentId: String,
        into directory: URL
    ) async throws -> URL {
        let url = try buildURL(
            endpoint: APIEndpoints.attachment(messageId: messageId, attachmentId: attachmentId)
        )
        let request = try await authenticatedRequest(url: url)
        let response = directory.appendingPathComponent("incoming_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: response) }

        try await performRetryingRequest(
            request,
            session: transferSession,
            downloadingTo: response,
            behavior: GmailRetryPathBehavior(
                allowsRetransmission: true,
                thrownAPIErrorsAbortImmediately: false,
                wrapsDecodingErrors: true,
                logContext: "Attachment download"
            )
        ) { statusCode, data in
            if let statusCode {
                switch statusCode {
                case 403:
                    throw self.classify403(from: data)
                case 404:
                    throw APIError.notFound(self.gmailErrorMessage(from: data) ?? "attachment")
                case 400...499:
                    let message = self.gmailErrorMessage(from: data)
                        ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
                    throw APIError.invalidData("Gmail API \(statusCode): \(message)")
                case 200...299:
                    // No error-envelope scan of a 2xx here: its body is the file, and a body
                    // with no `data` is refused by the decoder below.
                    break
                default:
                    throw APIError.invalidData("Gmail API \(statusCode)")
                }
            }
            await self.rateLimitTracker.recordSuccess()
        }

        let decoded = directory.appendingPathComponent("incoming_\(UUID().uuidString)")
        do {
            try GmailAttachmentBodyDecoder.decodeDataField(ofJSONFileAt: response, into: decoded)
        } catch let error as GmailAttachmentBodyDecoder.DecodeError {
            try? FileManager.default.removeItem(at: decoded)
            throw APIError.invalidData("Failed to decode attachment data from base64: \(error)")
        } catch {
            try? FileManager.default.removeItem(at: decoded)
            throw error
        }
        return decoded
    }
}
