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
final class GmailSendService: ObservableObject {

    // MARK: - Properties

    let apiClient: any GmailAPIClientProtocol
    let authSession: AuthSession
    let viewContext: NSManagedObjectContext

    // MARK: - Initialization

    @MainActor init(
        viewContext: NSManagedObjectContext,
        apiClient: (any GmailAPIClientProtocol)? = nil,
        authSession: AuthSession? = nil
    ) {
        self.viewContext = viewContext
        self.apiClient = apiClient ?? GmailAPIClient.shared
        self.authSession = authSession ?? .shared
    }

    // MARK: - Public API

    /// Sends a new email (not a reply).
    nonisolated func sendNew(
        to recipients: [String],
        body: String,
        htmlBody: String? = nil,
        subject: String? = nil,
        attachmentInfos: [AttachmentInfo] = [],
        inlineAttachmentInfos: [AttachmentInfo] = []
    ) async throws -> SendResult {
        let (fromEmail, fromName) = await MainActor.run { (authSession.userEmail, authSession.userName) }
        guard let fromEmail = fromEmail else {
            throw SendError.authenticationFailed
        }

        let attachmentData = try await prepareAttachmentInfos(attachmentInfos)
        let inlineAttachmentData = try await prepareInlineAttachmentInfos(inlineAttachmentInfos)
        let mimeData = MimeBuilder.buildNew(
            to: recipients,
            from: fromEmail,
            fromName: fromName,
            body: body,
            htmlBody: htmlBody,
            subject: subject,
            attachments: attachmentData,
            inlineAttachments: inlineAttachmentData
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
        do {
            let response = try await apiClient.sendMessage(
                rawMessage: rawMessage,
                threadId: threadId
            )

            Log.info("Message sent - ID: \(response.id)", category: .api)
            return SendResult(messageId: response.id, threadId: response.threadId)
        } catch let error as APIError {
            throw mapSendError(error)
        } catch {
            throw SendError.apiError(error.localizedDescription)
        }
    }

    private nonisolated func mapSendError(_ error: APIError) -> SendError {
        switch error {
        case .authenticationError:
            return .authenticationFailed
        case .invalidURL:
            return .apiError("Invalid API URL")
        default:
            return .apiError(error.localizedDescription)
        }
    }
}
