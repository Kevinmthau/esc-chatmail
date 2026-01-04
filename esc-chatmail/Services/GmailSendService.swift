import Foundation
import Combine
import CoreData

/// Service for sending emails via Gmail API.
///
/// The service is split across multiple files for organization:
/// - `GmailSendService.swift` - Core sending logic
/// - `GmailSendModels.swift` - SendResult, AttachmentInfo, SendError types
/// - `GmailSendService+Attachments.swift` - Attachment handling
/// - `GmailSendService+OptimisticUpdates.swift` - Optimistic UI message management
@MainActor
final class GmailSendService: ObservableObject {

    // MARK: - Properties

    let apiClient: GmailAPIClient
    let authSession: AuthSession
    let viewContext: NSManagedObjectContext

    // MARK: - Initialization

    init(
        viewContext: NSManagedObjectContext,
        apiClient: GmailAPIClient? = nil,
        authSession: AuthSession? = nil
    ) {
        self.viewContext = viewContext
        self.apiClient = apiClient ?? .shared
        self.authSession = authSession ?? .shared
    }

    // MARK: - Public API

    /// Sends a new email (not a reply).
    nonisolated func sendNew(
        to recipients: [String],
        body: String,
        subject: String? = nil,
        attachmentInfos: [AttachmentInfo] = []
    ) async throws -> SendResult {
        let (fromEmail, fromName) = await MainActor.run { (authSession.userEmail, authSession.userName) }
        guard let fromEmail = fromEmail else {
            throw SendError.authenticationFailed
        }

        let attachmentData = try await prepareAttachmentInfos(attachmentInfos)
        let mimeData = MimeBuilder.buildNew(
            to: recipients,
            from: fromEmail,
            fromName: fromName,
            body: body,
            subject: subject,
            attachments: attachmentData
        )

        return try await sendMessage(mimeData: mimeData, threadId: nil)
    }

    /// Sends a reply to an existing thread.
    nonisolated func sendReply(
        to recipients: [String],
        body: String,
        subject: String,
        threadId: String,
        inReplyTo: String?,
        references: [String],
        originalMessage: QuotedMessage? = nil,
        attachmentInfos: [AttachmentInfo] = []
    ) async throws -> SendResult {
        let (fromEmail, fromName) = await MainActor.run { (authSession.userEmail, authSession.userName) }
        guard let fromEmail = fromEmail else {
            throw SendError.authenticationFailed
        }

        let attachmentData = try await prepareAttachmentInfos(attachmentInfos)
        let mimeData = MimeBuilder.buildReply(
            to: recipients,
            from: fromEmail,
            fromName: fromName,
            body: body,
            subject: subject,
            inReplyTo: inReplyTo,
            references: references,
            originalMessage: originalMessage,
            attachments: attachmentData
        )

        return try await sendMessage(mimeData: mimeData, threadId: threadId)
    }

    // MARK: - Private

    /// Sends the MIME-encoded message to Gmail API.
    private nonisolated func sendMessage(mimeData: Data, threadId: String?) async throws -> SendResult {
        Log.debug("Sending MIME message (\(mimeData.count) bytes)", category: .api)

        let rawMessage = MimeBuilder.base64UrlEncode(mimeData)

        var requestBody: [String: Any] = ["raw": rawMessage]
        if let threadId = threadId {
            requestBody["threadId"] = threadId
        }

        let accessToken = try await authSession.withFreshToken()

        guard let url = URL(string: APIEndpoints.sendMessage()) else {
            throw SendError.apiError("Invalid API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw SendError.invalidMimeData
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SendError.apiError("Invalid response")
        }

        if httpResponse.statusCode == 401 {
            throw SendError.authenticationFailed
        }

        Log.debug("Response status: \(httpResponse.statusCode)", category: .api)

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SendError.apiError("Failed to send message: \(errorMessage)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = json["id"] as? String,
              let returnedThreadId = json["threadId"] as? String else {
            throw SendError.apiError("Invalid response format")
        }

        Log.info("Message sent - ID: \(messageId)", category: .api)

        return SendResult(messageId: messageId, threadId: returnedThreadId)
    }
}
