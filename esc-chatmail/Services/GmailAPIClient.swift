import Foundation

class GmailAPIClient {
    static let shared = GmailAPIClient()
    private let session = URLSession.shared
    private let authSession = AuthSession.shared
    
    private init() {}
    
    private func authenticatedRequest(url: URL) async throws -> URLRequest {
        var request = URLRequest(url: url)
        let token = try await authSession.withFreshToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    
    func getProfile() async throws -> GmailProfile {
        let url = URL(string: APIEndpoints.profile())!
        let request = try await authenticatedRequest(url: url)
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(GmailProfile.self, from: data)
    }
    
    func listLabels() async throws -> [GmailLabel] {
        let url = URL(string: APIEndpoints.labels())!
        let request = try await authenticatedRequest(url: url)
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(LabelsResponse.self, from: data)
        return response.labels ?? []
    }
    
    func listMessages(pageToken: String? = nil, maxResults: Int = 100) async throws -> MessagesListResponse {
        var components = URLComponents(string: APIEndpoints.messages())!
        components.queryItems = [
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]
        if let pageToken = pageToken {
            components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        
        let request = try await authenticatedRequest(url: components.url!)
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(MessagesListResponse.self, from: data)
    }
    
    func getMessage(id: String, format: String = "full") async throws -> GmailMessage {
        var components = URLComponents(string: APIEndpoints.message(id: id))!
        components.queryItems = [URLQueryItem(name: "format", value: format)]
        
        let request = try await authenticatedRequest(url: components.url!)
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(GmailMessage.self, from: data)
    }
    
    func modifyMessage(id: String, addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) async throws -> GmailMessage {
        let url = URL(string: APIEndpoints.modifyMessage(id: id))!
        var request = try await authenticatedRequest(url: url)
        request.httpMethod = "POST"
        
        let body = ModifyMessageRequest(addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(GmailMessage.self, from: data)
    }
    
    func batchModify(ids: [String], addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) async throws {
        let url = URL(string: APIEndpoints.batchModify())!
        var request = try await authenticatedRequest(url: url)
        request.httpMethod = "POST"
        
        let body = BatchModifyRequest(ids: ids, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (_, _) = try await session.data(for: request)
    }
    
    func listHistory(startHistoryId: String, pageToken: String? = nil) async throws -> HistoryResponse {
        var components = URLComponents(string: APIEndpoints.history())!
        components.queryItems = [
            URLQueryItem(name: "startHistoryId", value: startHistoryId)
        ]
        if let pageToken = pageToken {
            components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        
        let request = try await authenticatedRequest(url: components.url!)
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(HistoryResponse.self, from: data)
    }
    
    func listSendAs() async throws -> [SendAs] {
        let url = URL(string: APIEndpoints.sendAs())!
        let request = try await authenticatedRequest(url: url)
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(SendAsListResponse.self, from: data)
        return response.sendAs ?? []
    }
    
    func getAttachment(messageId: String, attachmentId: String) async throws -> Data {
        let url = URL(string: APIEndpoints.attachment(messageId: messageId, attachmentId: attachmentId))!
        let request = try await authenticatedRequest(url: url)
        let (data, _) = try await session.data(for: request)
        
        struct AttachmentResponse: Codable {
            let size: Int
            let data: String
        }
        
        let response = try JSONDecoder().decode(AttachmentResponse.self, from: data)
        
        guard let attachmentData = Data(base64UrlEncoded: response.data) else {
            throw NSError(domain: "GmailAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode attachment data"])
        }
        
        return attachmentData
    }
}

extension Data {
    init?(base64UrlEncoded: String) {
        var base64 = base64UrlEncoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        
        self.init(base64Encoded: base64)
    }
    
    func base64UrlEncodedString() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

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