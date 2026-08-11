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
        inlineAttachmentInfos: [AttachmentInfo] = [],
        messageId: String? = nil,
        beforeTransmission: @Sendable () async throws -> Void = {}
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
            inlineAttachments: inlineAttachmentData,
            messageId: messageId
        )

        return try await sendMessage(
            mimeData: mimeData,
            threadId: nil,
            beforeTransmission: beforeTransmission
        )
    }

    /// Sends a reply to an existing thread.
    nonisolated func sendReply(
        to recipients: [String],
        fromEmail: String? = nil,
        fromName: String? = nil,
        body: String,
        subject: String,
        threadId: String,
        inReplyTo: String?,
        references: [String],
        originalMessage: QuotedMessage? = nil,
        attachmentInfos: [AttachmentInfo] = [],
        messageId: String? = nil,
        beforeTransmission: @Sendable () async throws -> Void = {}
    ) async throws -> SendResult {
        let sessionFrom = await MainActor.run { (authSession.userEmail, authSession.userName) }
        let resolvedFromEmail = fromEmail ?? sessionFrom.0
        let resolvedFromName = fromName ?? sessionFrom.1
        guard let resolvedFromEmail else {
            throw SendError.authenticationFailed
        }

        let attachmentData = try await prepareAttachmentInfos(attachmentInfos)
        let mimeData = MimeBuilder.buildReply(
            to: recipients,
            from: resolvedFromEmail,
            fromName: resolvedFromName,
            body: body,
            subject: subject,
            inReplyTo: inReplyTo,
            references: references,
            originalMessage: originalMessage,
            attachments: attachmentData,
            messageId: messageId
        )

        return try await sendMessage(
            mimeData: mimeData,
            threadId: threadId,
            beforeTransmission: beforeTransmission
        )
    }

    // MARK: - Private

    /// Sends the MIME-encoded message to Gmail API.
    private nonisolated func sendMessage(
        mimeData: Data,
        threadId: String?,
        beforeTransmission: @Sendable () async throws -> Void
    ) async throws -> SendResult {
        Log.debug("Sending MIME message (\(mimeData.count) bytes)", category: .api)

        let rawMessage = MimeBuilder.base64UrlEncode(mimeData)

        do {
            let response = try await apiClient.sendMessage(
                rawMessage: rawMessage,
                threadId: threadId,
                beforeTransmission: beforeTransmission
            )

            Log.info("Message sent - ID: \(response.id)", category: .api)
            return SendResult(messageId: response.id, threadId: response.threadId)
        } catch let error as GmailMessageSendError {
            switch error {
            case .transmissionNotStarted(let underlying):
                throw underlying
            case .ambiguousDelivery:
                throw SendError.ambiguousDelivery(error.localizedDescription)
            }
        } catch let error as APIError {
            throw mapSendError(error)
        } catch is CancellationError {
            // A custom API client may surface cancellation directly. Once the
            // call began, conservatively preserve it as an ambiguous send.
            throw SendError.ambiguousDelivery("Gmail may have accepted the message before cancellation")
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
        case .serverError, .timeout, .decodingError:
            return .ambiguousDelivery(error.localizedDescription)
        case .networkError(let underlying):
            if ConnectionErrorDetector.isPreTransmissionError(underlying) {
                return .apiError(error.localizedDescription)
            }
            return .ambiguousDelivery(error.localizedDescription)
        default:
            return .apiError(error.localizedDescription)
        }
    }
}
