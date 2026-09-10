import Foundation
import CoreData

enum OutboundSendRemoteState {
    static let inFlightMessageID = "__esc_in_flight_remote_send_v1__"
    static let ambiguousMessageID = "__esc_ambiguous_remote_send_v1__"
    static let notSentMessageID = "__esc_definite_remote_send_failure_v1__"

    static func deliveryState(
        messageID: String?,
        threadID: String?
    ) -> OutboundSendDeliveryState {
        guard threadID == nil else { return .none }

        switch messageID {
        case nil:
            // Optimistic creation durably saves the record before MIME/attachment
            // preflight. While this process is alive that definite pre-admission
            // state is still active work; cold recovery converts it to Not sent.
            return .sending
        case inFlightMessageID:
            return .sending
        case ambiguousMessageID:
            return .deliveryUnknown
        case notSentMessageID:
            return .notSent
        default:
            return .none
        }
    }

    static func isLocalMarker(_ messageID: String?) -> Bool {
        messageID == inFlightMessageID ||
            messageID == ambiguousMessageID ||
            messageID == notSentMessageID
    }
}

enum OutboundSendDeliveryState: Equatable, Sendable {
    case none
    case sending
    case notSent
    case deliveryUnknown

    @MainActor
    static func localOptimisticMessageID(for message: Message) -> String? {
        guard message.isFromMe,
              let rfcMessageID = message.messageIdValue,
              MimeBuilder.optimisticMessageID(from: rfcMessageID) == message.id else {
            return nil
        }
        return message.id
    }

    @MainActor
    static func resolve(for message: Message) -> Self {
        guard let optimisticMessageID = localOptimisticMessageID(for: message),
              let context = message.managedObjectContext else {
            return .none
        }

        let request = OutboundSendMutationRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", optimisticMessageID)
        request.fetchLimit = 1
        request.fetchBatchSize = 1
        request.includesPendingChanges = true

        guard let record = try? context.fetch(request).first else {
            return .none
        }
        return OutboundSendRemoteState.deliveryState(
            messageID: record.remoteCommittedMessageId,
            threadID: record.remoteCommittedThreadId
        )
    }
}

enum GmailMessageSendError: LocalizedError {
    case transmissionNotStarted(Error)
    case ambiguousDelivery(Error)

    var errorDescription: String? {
        switch self {
        case .transmissionNotStarted(let error):
            return error.localizedDescription
        case .ambiguousDelivery(let error):
            return "Gmail may have accepted the message: \(error.localizedDescription)"
        }
    }
}

// MARK: - Send Models

extension GmailSendService {

    /// Result of a successful message send operation.
    struct SendResult: Sendable {
        let messageId: String
        let threadId: String
    }

    /// Information about an attachment to be sent.
    struct AttachmentInfo: Sendable {
        let localURL: String?
        let filename: String
        let mimeType: String
        let contentId: String?

        init(localURL: String?, filename: String, mimeType: String, contentId: String? = nil) {
            self.localURL = localURL
            self.filename = filename
            self.mimeType = mimeType
            self.contentId = contentId
        }
    }

    /// Errors that can occur during message sending.
    enum SendError: LocalizedError, Sendable {
        case invalidMimeData
        case apiError(String)
        case authenticationFailed
        case optimisticCreationFailed
        case conversationNotFound
        case noRecipients
        case replyTargetUnavailable
        case sendAsAliasUnavailable(String)
        case ambiguousDelivery(String)

        var errorDescription: String? {
            switch self {
            case .invalidMimeData:
                return "Failed to create message data"
            case .apiError(let message):
                return message
            case .authenticationFailed:
                return "Authentication failed"
            case .optimisticCreationFailed:
                return "Failed to prepare message for sending"
            case .conversationNotFound:
                return "Failed to find conversation for message"
            case .noRecipients:
                return "This message has no recipients. Your draft and attachments are still here."
            case .replyTargetUnavailable:
                return "The message you selected moved or is no longer available. Reopen the conversation and try again."
            case .sendAsAliasUnavailable(let address):
                return "This message was sent to \(address), but Gmail is not configured to send from that address. Add it in Gmail Settings -> Accounts -> Send mail as."
            case .ambiguousDelivery(let message):
                return message
            }
        }
    }
}
