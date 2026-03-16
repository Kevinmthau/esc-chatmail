import Foundation
import CoreData

@MainActor
protocol IncrementalSyncPerforming: AnyObject {
    func performIncrementalSync() async throws
}

extension SyncEngine: IncrementalSyncPerforming {}

protocol ComposeSendServicing: AnyObject {
    @MainActor func markAttachmentsAsUploaded(_ attachments: [Attachment])
    func sendReply(
        to recipients: [String],
        body: String,
        subject: String,
        threadId: String,
        inReplyTo: String?,
        references: [String],
        originalMessage: QuotedMessage?,
        attachmentInfos: [GmailSendService.AttachmentInfo]
    ) async throws -> GmailSendService.SendResult
    func sendNew(
        to recipients: [String],
        body: String,
        htmlBody: String?,
        subject: String?,
        attachmentInfos: [GmailSendService.AttachmentInfo],
        inlineAttachmentInfos: [GmailSendService.AttachmentInfo]
    ) async throws -> GmailSendService.SendResult
    @MainActor func fetchMessageSync(byID messageID: String) -> Message?
    @MainActor func updateOptimisticMessage(_ message: Message, with result: GmailSendService.SendResult)
    @MainActor func markAttachmentsAsFailed(_ attachments: [Attachment])
    @MainActor func handleFailedOptimisticMessage(byID messageID: String, fallbackAttachments: [Attachment])
}

extension GmailSendService: ComposeSendServicing {}

/// Orchestrates the message sending flow, handling optimistic updates and background execution
struct ComposeSendOrchestrator {
    let sendService: ComposeSendServicing
    let syncPerformer: IncrementalSyncPerforming

    /// Input data for sending a message
    struct SendInput: Sendable {
        let recipientEmails: [String]
        let body: String
        let htmlBody: String?
        let subject: String?
        let attachmentInfos: [GmailSendService.AttachmentInfo]
        let inlineAttachmentInfos: [GmailSendService.AttachmentInfo]
        let replyData: ReplyData?

        /// Reply-specific data extracted before background execution
        struct ReplyData: Sendable {
            let recipients: [String]
            let body: String
            let subject: String?
            let threadId: String?
            let inReplyTo: String?
            let references: [String]
            let originalMessage: QuotedMessage?
        }
    }

    /// Creates an optimistic message and triggers background send
    /// - Parameters:
    ///   - input: The send input data
    ///   - attachments: Original attachment entities for marking as uploaded
    ///   - optimisticMessageID: ID of the pre-created optimistic message
    @MainActor
    @discardableResult
    func executeInBackground(
        input: SendInput,
        attachments: [Attachment],
        optimisticMessageID: String
    ) -> Task<Void, Never> {
        // Capture services for background task
        let sendService = self.sendService
        let syncPerformer = self.syncPerformer

        // Send in background - don't wait for completion
        return Task.detached(priority: .userInitiated) {
            do {
                let result: GmailSendService.SendResult

                if let replyData = input.replyData {
                    result = try await sendService.sendReply(
                        to: replyData.recipients,
                        body: replyData.body,
                        subject: replyData.subject ?? "",
                        threadId: replyData.threadId ?? "",
                        inReplyTo: replyData.inReplyTo,
                        references: replyData.references,
                        originalMessage: replyData.originalMessage,
                        attachmentInfos: input.attachmentInfos
                    )
                } else {
                    result = try await sendService.sendNew(
                        to: input.recipientEmails,
                        body: input.body,
                        htmlBody: input.htmlBody,
                        subject: input.subject,
                        attachmentInfos: input.attachmentInfos,
                        inlineAttachmentInfos: input.inlineAttachmentInfos
                    )
                }

                // Update optimistic message with real IDs (on MainActor to avoid Sendable issues)
                await MainActor.run {
                    if let message = sendService.fetchMessageSync(byID: optimisticMessageID) {
                        sendService.updateOptimisticMessage(message, with: result)
                    }
                    sendService.markAttachmentsAsUploaded(attachments)
                }

                if Task.isCancelled {
                    Log.info(
                        "Background send completed after cancellation for optimistic message \(optimisticMessageID); skipping post-send sync",
                        category: .message
                    )
                    return
                }

                // Trigger sync to fetch the sent message from Gmail
                // Sync failure is non-critical - message was sent successfully, user will
                // see it on next sync. Log warning for debugging but don't surface to user.
                do {
                    try await syncPerformer.performIncrementalSync()
                } catch {
                    Log.warning("Post-send sync failed - sent message will appear on next sync: \(error.localizedDescription)", category: .sync)
                }
            } catch is CancellationError {
                await MainActor.run {
                    sendService.handleFailedOptimisticMessage(
                        byID: optimisticMessageID,
                        fallbackAttachments: attachments
                    )
                }
                Log.info("Background send cancelled for optimistic message \(optimisticMessageID)", category: .message)
            } catch {
                // Clean up optimistic state using the same failure policy as the chat reply path.
                await MainActor.run {
                    sendService.handleFailedOptimisticMessage(
                        byID: optimisticMessageID,
                        fallbackAttachments: attachments
                    )
                }
                Log.error("Background send failed", category: .message, error: error)
            }
        }
    }
}
