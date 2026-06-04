import Foundation

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
        case sendAsAliasUnavailable(String)

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
            case .sendAsAliasUnavailable(let address):
                return "This message was sent to \(address), but Gmail is not configured to send from that address. Add it in Gmail Settings -> Accounts -> Send mail as."
            }
        }
    }
}
