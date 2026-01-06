import Foundation
import CoreData

/// Orchestrates the message sending flow, handling optimistic updates and background execution
struct ComposeSendOrchestrator {
    let sendService: GmailSendService
    let syncEngine: SyncEngine

    /// Input data for sending a message
    struct SendInput: Sendable {
        let recipientEmails: [String]
        let body: String
        let subject: String?
        let attachmentInfos: [GmailSendService.AttachmentInfo]
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
    func executeInBackground(
        input: SendInput,
        attachments: [Attachment],
        optimisticMessageID: String
    ) {
        // Mark attachments as uploaded immediately so they display non-dimmed
        sendService.markAttachmentsAsUploaded(attachments)

        // Capture services for background task
        let sendService = self.sendService
        let syncEngine = self.syncEngine

        // Send in background - don't wait for completion
        Task.detached {
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
                        subject: input.subject,
                        attachmentInfos: input.attachmentInfos
                    )
                }

                // Update optimistic message with real IDs
                await MainActor.run {
                    if let message = sendService.fetchMessage(byID: optimisticMessageID) {
                        sendService.updateOptimisticMessage(message, with: result)
                    }
                }

                // Trigger sync to fetch the sent message from Gmail
                try? await syncEngine.performIncrementalSync()

            } catch {
                // Mark attachments as failed so they show error indicator
                await MainActor.run {
                    if let message = sendService.fetchMessage(byID: optimisticMessageID) {
                        sendService.markAttachmentsAsFailed(message.attachmentsArray)
                    }
                }
                Log.error("Background send failed", category: .message, error: error)
            }
        }
    }
}
