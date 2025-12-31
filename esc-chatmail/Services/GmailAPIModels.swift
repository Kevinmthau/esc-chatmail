import Foundation

// MARK: - Gmail API Response Types

struct GmailProfile: Codable {
    let emailAddress: String
    let messagesTotal: Int?
    let threadsTotal: Int?
    let historyId: String
}

struct GmailLabel: Codable {
    let id: String
    let name: String
    let messageListVisibility: String?
    let labelListVisibility: String?
    let type: String?
}

struct LabelsResponse: Codable {
    let labels: [GmailLabel]?
}

struct MessagesListResponse: Codable {
    let messages: [MessageListItem]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

struct MessageListItem: Codable {
    let id: String
    let threadId: String?
}

struct GmailMessage: Codable {
    let id: String
    let threadId: String?
    let labelIds: [String]?
    let snippet: String?
    let historyId: String?
    let internalDate: String?
    let payload: MessagePart?
    let sizeEstimate: Int?
}

struct MessagePart: Codable {
    let partId: String?
    let mimeType: String?
    let filename: String?
    let headers: [MessageHeader]?
    let body: MessageBody?
    let parts: [MessagePart]?
}

struct MessageHeader: Codable {
    let name: String
    let value: String
}

struct MessageBody: Codable {
    let size: Int?
    let data: String?
    let attachmentId: String?
}

struct ModifyMessageRequest: Codable {
    let addLabelIds: [String]?
    let removeLabelIds: [String]?
}

struct BatchModifyRequest: Codable {
    let ids: [String]
    let addLabelIds: [String]?
    let removeLabelIds: [String]?
}

// MARK: - History API Types

struct HistoryResponse: Codable {
    let history: [HistoryRecord]?
    let nextPageToken: String?
    let historyId: String?
}

struct HistoryRecord: Codable {
    let id: String
    let messages: [GmailMessage]?
    let messagesAdded: [HistoryMessageAdded]?
    let messagesDeleted: [HistoryMessageDeleted]?
    let labelsAdded: [HistoryLabelAdded]?
    let labelsRemoved: [HistoryLabelRemoved]?
}

struct HistoryMessageAdded: Codable {
    let message: GmailMessage
}

struct HistoryMessageDeleted: Codable {
    let message: MessageListItem
}

struct HistoryLabelAdded: Codable {
    let message: MessageListItem
    let labelIds: [String]
}

struct HistoryLabelRemoved: Codable {
    let message: MessageListItem
    let labelIds: [String]
}

// MARK: - Send As Types

struct SendAsListResponse: Codable {
    let sendAs: [SendAs]?
}

struct SendAs: Codable {
    let sendAsEmail: String
    let displayName: String?
    let replyToAddress: String?
    let signature: String?
    let isPrimary: Bool?
    let isDefault: Bool?
    let treatAsAlias: Bool?
    let verificationStatus: String?
}

