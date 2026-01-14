import Foundation
@testable import esc_chatmail

/// Mock implementation of GmailAPIClientProtocol for testing.
/// Allows controlling API responses and simulating errors without network calls.
final class MockGmailAPIClient: GmailAPIClientProtocol, @unchecked Sendable {

    // MARK: - Configurable Responses

    /// Response for listMessages() calls
    var listMessagesResponse: MessagesListResponse = MessagesListResponse(messages: [], nextPageToken: nil, resultSizeEstimate: 0)

    /// Responses for getMessage() calls, keyed by message ID
    var getMessageResponses: [String: GmailMessage] = [:]

    /// Default response for getMessage() when no specific response is configured
    var defaultGetMessageResponse: GmailMessage?

    /// Response for modifyMessage() calls
    var modifyMessageResponse: GmailMessage?

    /// Response for getProfile() calls
    var profileResponse: GmailProfile = GmailProfile(
        emailAddress: "test@example.com",
        messagesTotal: 100,
        threadsTotal: 50,
        historyId: "12345"
    )

    /// Response for listLabels() calls
    var labelsResponse: [GmailLabel] = []

    /// Response for listSendAs() calls
    var sendAsResponse: [SendAs] = []

    /// Response for listHistory() calls
    var historyResponse: HistoryResponse = HistoryResponse(history: nil, nextPageToken: nil, historyId: "12345")

    /// Response for getAttachment() calls, keyed by "messageId:attachmentId"
    var attachmentResponses: [String: Data] = [:]

    // MARK: - Error Simulation

    /// Error to throw on listMessages() (resets after throwing)
    var listMessagesError: Error?

    /// Error to throw on getMessage() (resets after throwing)
    var getMessageError: Error?

    /// Errors to throw for specific message IDs
    var getMessageErrors: [String: Error] = [:]

    /// Error to throw on modifyMessage() (resets after throwing)
    var modifyMessageError: Error?

    /// Error to throw on batchModify() (resets after throwing)
    var batchModifyError: Error?

    /// Error to throw on getProfile() (resets after throwing)
    var getProfileError: Error?

    /// Error to throw on listLabels() (resets after throwing)
    var listLabelsError: Error?

    /// Error to throw on listSendAs() (resets after throwing)
    var listSendAsError: Error?

    /// Error to throw on listHistory() (resets after throwing)
    var listHistoryError: Error?

    /// Error to throw on getAttachment() (resets after throwing)
    var getAttachmentError: Error?

    // MARK: - Call Tracking

    private(set) var listMessagesCallCount = 0
    private(set) var listMessagesLastQuery: String?
    private(set) var listMessagesLastMaxResults: Int?
    private(set) var listMessagesLastPageToken: String?

    private(set) var getMessageCallCount = 0
    private(set) var getMessageCalledIds: [String] = []

    private(set) var modifyMessageCallCount = 0
    private(set) var modifyMessageCalls: [(id: String, add: [String]?, remove: [String]?)] = []

    private(set) var batchModifyCallCount = 0
    private(set) var batchModifyCalls: [(ids: [String], add: [String]?, remove: [String]?)] = []

    private(set) var archiveMessagesCallCount = 0
    private(set) var archiveMessagesCalledIds: [[String]] = []

    private(set) var getProfileCallCount = 0
    private(set) var listLabelsCallCount = 0
    private(set) var listSendAsCallCount = 0

    private(set) var listHistoryCallCount = 0
    private(set) var listHistoryLastStartId: String?

    private(set) var getAttachmentCallCount = 0
    private(set) var getAttachmentCalls: [(messageId: String, attachmentId: String)] = []

    // MARK: - Artificial Delays

    /// Delay to simulate network latency (in seconds)
    var artificialDelay: TimeInterval = 0

    // MARK: - Reset

    /// Resets all state to defaults
    func reset() {
        // Responses
        listMessagesResponse = MessagesListResponse(messages: [], nextPageToken: nil, resultSizeEstimate: 0)
        getMessageResponses = [:]
        defaultGetMessageResponse = nil
        modifyMessageResponse = nil
        profileResponse = GmailProfile(emailAddress: "test@example.com", messagesTotal: 100, threadsTotal: 50, historyId: "12345")
        labelsResponse = []
        sendAsResponse = []
        historyResponse = HistoryResponse(history: nil, nextPageToken: nil, historyId: "12345")
        attachmentResponses = [:]

        // Errors
        listMessagesError = nil
        getMessageError = nil
        getMessageErrors = [:]
        modifyMessageError = nil
        batchModifyError = nil
        getProfileError = nil
        listLabelsError = nil
        listSendAsError = nil
        listHistoryError = nil
        getAttachmentError = nil

        // Call tracking
        listMessagesCallCount = 0
        listMessagesLastQuery = nil
        listMessagesLastMaxResults = nil
        listMessagesLastPageToken = nil
        getMessageCallCount = 0
        getMessageCalledIds = []
        modifyMessageCallCount = 0
        modifyMessageCalls = []
        batchModifyCallCount = 0
        batchModifyCalls = []
        archiveMessagesCallCount = 0
        archiveMessagesCalledIds = []
        getProfileCallCount = 0
        listLabelsCallCount = 0
        listSendAsCallCount = 0
        listHistoryCallCount = 0
        listHistoryLastStartId = nil
        getAttachmentCallCount = 0
        getAttachmentCalls = []

        artificialDelay = 0
    }

    // MARK: - GmailAPIClientProtocol Implementation

    func listMessages(pageToken: String?, maxResults: Int, query: String?) async throws -> MessagesListResponse {
        listMessagesCallCount += 1
        listMessagesLastQuery = query
        listMessagesLastMaxResults = maxResults
        listMessagesLastPageToken = pageToken

        if artificialDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(artificialDelay * 1_000_000_000))
        }

        if let error = listMessagesError {
            listMessagesError = nil
            throw error
        }

        return listMessagesResponse
    }

    func getMessage(id: String, format: String) async throws -> GmailMessage {
        getMessageCallCount += 1
        getMessageCalledIds.append(id)

        if artificialDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(artificialDelay * 1_000_000_000))
        }

        if let error = getMessageErrors[id] {
            throw error
        }

        if let error = getMessageError {
            getMessageError = nil
            throw error
        }

        if let response = getMessageResponses[id] {
            return response
        }

        if let defaultResponse = defaultGetMessageResponse {
            return GmailMessage(
                id: id,
                threadId: defaultResponse.threadId,
                labelIds: defaultResponse.labelIds,
                snippet: defaultResponse.snippet,
                historyId: defaultResponse.historyId,
                internalDate: defaultResponse.internalDate,
                payload: defaultResponse.payload,
                sizeEstimate: defaultResponse.sizeEstimate
            )
        }

        throw APIError.notFound("Message \(id)")
    }

    func modifyMessage(id: String, addLabelIds: [String]?, removeLabelIds: [String]?) async throws -> GmailMessage {
        modifyMessageCallCount += 1
        modifyMessageCalls.append((id: id, add: addLabelIds, remove: removeLabelIds))

        if artificialDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(artificialDelay * 1_000_000_000))
        }

        if let error = modifyMessageError {
            modifyMessageError = nil
            throw error
        }

        if let response = modifyMessageResponse {
            return response
        }

        // Return a message with updated labels
        let existingLabels = getMessageResponses[id]?.labelIds ?? []
        var newLabels = existingLabels
        if let remove = removeLabelIds {
            newLabels = newLabels.filter { !remove.contains($0) }
        }
        if let add = addLabelIds {
            newLabels.append(contentsOf: add.filter { !newLabels.contains($0) })
        }

        return GmailMessage(
            id: id,
            threadId: getMessageResponses[id]?.threadId,
            labelIds: newLabels,
            snippet: getMessageResponses[id]?.snippet,
            historyId: nil,
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil
        )
    }

    func batchModify(ids: [String], addLabelIds: [String]?, removeLabelIds: [String]?) async throws {
        batchModifyCallCount += 1
        batchModifyCalls.append((ids: ids, add: addLabelIds, remove: removeLabelIds))

        if artificialDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(artificialDelay * 1_000_000_000))
        }

        if let error = batchModifyError {
            batchModifyError = nil
            throw error
        }
    }

    func archiveMessages(ids: [String]) async throws {
        archiveMessagesCallCount += 1
        archiveMessagesCalledIds.append(ids)
        try await batchModify(ids: ids, addLabelIds: nil, removeLabelIds: ["INBOX"])
    }

    func getProfile() async throws -> GmailProfile {
        getProfileCallCount += 1

        if artificialDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(artificialDelay * 1_000_000_000))
        }

        if let error = getProfileError {
            getProfileError = nil
            throw error
        }

        return profileResponse
    }

    func listLabels() async throws -> [GmailLabel] {
        listLabelsCallCount += 1

        if artificialDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(artificialDelay * 1_000_000_000))
        }

        if let error = listLabelsError {
            listLabelsError = nil
            throw error
        }

        return labelsResponse
    }

    func listSendAs() async throws -> [SendAs] {
        listSendAsCallCount += 1

        if artificialDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(artificialDelay * 1_000_000_000))
        }

        if let error = listSendAsError {
            listSendAsError = nil
            throw error
        }

        return sendAsResponse
    }

    func listHistory(startHistoryId: String, pageToken: String?) async throws -> HistoryResponse {
        listHistoryCallCount += 1
        listHistoryLastStartId = startHistoryId

        if artificialDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(artificialDelay * 1_000_000_000))
        }

        if let error = listHistoryError {
            listHistoryError = nil
            throw error
        }

        return historyResponse
    }

    func getAttachment(messageId: String, attachmentId: String) async throws -> Data {
        getAttachmentCallCount += 1
        getAttachmentCalls.append((messageId: messageId, attachmentId: attachmentId))

        if artificialDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(artificialDelay * 1_000_000_000))
        }

        if let error = getAttachmentError {
            getAttachmentError = nil
            throw error
        }

        let key = "\(messageId):\(attachmentId)"
        if let data = attachmentResponses[key] {
            return data
        }

        throw APIError.notFound("Attachment \(attachmentId)")
    }
}

// MARK: - Test Helpers

extension MockGmailAPIClient {
    /// Configures the mock to simulate rate limiting
    func simulateRateLimited() {
        listMessagesError = APIError.rateLimited
        getMessageError = APIError.rateLimited
    }

    /// Configures the mock to simulate authentication failure
    func simulateAuthFailure() {
        listMessagesError = APIError.authenticationError
        getMessageError = APIError.authenticationError
        getProfileError = APIError.authenticationError
    }

    /// Configures the mock to simulate server errors
    func simulateServerError(code: Int = 500) {
        listMessagesError = APIError.serverError(code)
        getMessageError = APIError.serverError(code)
    }

    /// Configures the mock to simulate expired history ID
    func simulateHistoryExpired() {
        listHistoryError = APIError.historyIdExpired
    }

    /// Configures the mock to simulate network timeout
    func simulateTimeout() {
        listMessagesError = APIError.timeout
        getMessageError = APIError.timeout
    }

    /// Adds a message response for a specific ID
    func addMessage(_ message: GmailMessage) {
        getMessageResponses[message.id] = message
    }

    /// Adds multiple message responses
    func addMessages(_ messages: [GmailMessage]) {
        for message in messages {
            getMessageResponses[message.id] = message
        }
    }

    /// Configures listMessages to return the specified message IDs
    func setMessageList(_ ids: [String], threadIds: [String]? = nil) {
        let items = ids.enumerated().map { index, id in
            MessageListItem(id: id, threadId: threadIds?[safe: index])
        }
        listMessagesResponse = MessagesListResponse(messages: items, nextPageToken: nil, resultSizeEstimate: items.count)
    }

    /// Configures listMessages with pagination
    func setMessageListWithPagination(_ pages: [[String]], pageTokens: [String?]) {
        // This would need to be more sophisticated for real pagination testing
        // For now, just set the first page
        if let firstPage = pages.first {
            setMessageList(firstPage)
            listMessagesResponse = MessagesListResponse(
                messages: firstPage.map { MessageListItem(id: $0, threadId: nil) },
                nextPageToken: pageTokens.first ?? nil,
                resultSizeEstimate: firstPage.count
            )
        }
    }

    /// Configures standard Gmail labels
    func setStandardLabels() {
        labelsResponse = [
            GmailLabel(id: "INBOX", name: "INBOX", messageListVisibility: "show", labelListVisibility: "labelShow", type: "system"),
            GmailLabel(id: "SENT", name: "SENT", messageListVisibility: "show", labelListVisibility: "labelShow", type: "system"),
            GmailLabel(id: "DRAFT", name: "DRAFT", messageListVisibility: "show", labelListVisibility: "labelShow", type: "system"),
            GmailLabel(id: "TRASH", name: "TRASH", messageListVisibility: "show", labelListVisibility: "labelShow", type: "system"),
            GmailLabel(id: "SPAM", name: "SPAM", messageListVisibility: "hide", labelListVisibility: "labelHide", type: "system"),
            GmailLabel(id: "UNREAD", name: "UNREAD", messageListVisibility: "hide", labelListVisibility: "labelHide", type: "system"),
            GmailLabel(id: "STARRED", name: "STARRED", messageListVisibility: "show", labelListVisibility: "labelShow", type: "system")
        ]
    }
}

// MARK: - Array Safe Access

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
