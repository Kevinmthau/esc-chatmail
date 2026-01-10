import Foundation

// MARK: - Send Models

extension GmailSendService {

    /// Result of a successful message send operation.
    struct SendResult {
        let messageId: String
        let threadId: String
    }

    /// Information about an attachment to be sent.
    struct AttachmentInfo: Sendable {
        let localURL: String?
        let filename: String
        let mimeType: String
    }

    /// Errors that can occur during message sending.
    enum SendError: LocalizedError {
        case invalidMimeData
        case apiError(String)
        case authenticationFailed
        case optimisticCreationFailed

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
            }
        }
    }
}
