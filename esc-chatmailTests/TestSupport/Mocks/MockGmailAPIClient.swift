import Foundation
@testable import esc_chatmail

/// Mock implementation of GmailAPIClientProtocol for testing.
/// Allows controlling API responses and simulating errors without network calls.
final class MockGmailAPIClient: GmailAPIClientProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private static let firstPageTokenKey = "__first_page__"

    // MARK: - Configurable Responses

    /// Response for listMessages() calls
    var listMessagesResponse: MessagesListResponse = MessagesListResponse(messages: [], nextPageToken: nil, resultSizeEstimate: 0)
    /// Optional page-token keyed responses for pagination tests
    /// Key uses "__first_page__" for nil pageToken.
    var paginatedListMessagesResponses: [String: MessagesListResponse] = [:]

    /// Responses for getMessage() calls, keyed by message ID
    var getMessageResponses: [String: GmailMessage] = [:]

    /// Default response for getMessage() when no specific response is configured
    var defaultGetMessageResponse: GmailMessage?

    /// Response for modifyMessage() calls
    var modifyMessageResponse: GmailMessage?

    /// Response for sendMessage() calls
    var sendMessageResponse: SendMessageResponse = SendMessageResponse(id: "sent-message-id", threadId: "sent-thread-id")

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
    /// Optional page-token keyed responses for pagination tests
    /// Key uses "__first_page__" for nil pageToken.
    var paginatedHistoryResponses: [String: HistoryResponse] = [:]

    /// Response for getAttachment() calls, keyed by "messageId:attachmentId"
    var attachmentResponses: [String: Data] = [:]

    // MARK: - Error Simulation

    /// Error to throw on listMessages() (resets after throwing)
    var listMessagesError: Error?
    /// Optional page-token keyed listMessages() errors (reset after throwing).
    var listMessagesErrorsByPageToken: [String: Error] = [:]

    /// Error to throw on getMessage() (resets after throwing)
    var getMessageError: Error?

    /// Errors to throw for specific message IDs
    var getMessageErrors: [String: Error] = [:]

    /// Error to throw on modifyMessage() (resets after throwing)
    var modifyMessageError: Error?

    /// Error to throw on sendMessage() (resets after throwing)
    var sendMessageError: Error?

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
    private(set) var getMessageCalledFormats: [String] = []

    private(set) var modifyMessageCallCount = 0
    private(set) var modifyMessageCalls: [(id: String, add: [String]?, remove: [String]?)] = []

    private(set) var sendMessageCallCount = 0
    private(set) var sendMessageCalls: [(rawMessage: String, threadId: String?)] = []

    private(set) var batchModifyCallCount = 0
    private(set) var batchModifyCalls: [(ids: [String], add: [String]?, remove: [String]?)] = []

    private(set) var archiveMessagesCallCount = 0
    private(set) var archiveMessagesCalledIds: [[String]] = []

    private(set) var getProfileCallCount = 0
    private(set) var listLabelsCallCount = 0
    private(set) var listSendAsCallCount = 0

    private(set) var listHistoryCallCount = 0
    private(set) var listHistoryLastStartId: String?
    private(set) var listHistoryLastPageToken: String?
    private(set) var listHistoryLastMaxResults: Int?
    /// Cross-endpoint call order ("getProfile"/"listMessages"), for pinning
    /// sequencing contracts such as the pre-scan recovery watermark.
    private(set) var endpointCallOrder: [String] = []

    private(set) var getAttachmentCallCount = 0
    private(set) var getAttachmentCalls: [(messageId: String, attachmentId: String)] = []

    // MARK: - Artificial Delays

    /// Delay to simulate network latency (in seconds)
    var artificialDelay: TimeInterval = 0

    @inline(__always)
    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    private func pageTokenKey(_ pageToken: String?) -> String {
        pageToken ?? Self.firstPageTokenKey
    }

    // MARK: - Reset

    /// Resets all state to defaults
    func reset() {
        withStateLock {
            // Responses
            listMessagesResponse = MessagesListResponse(messages: [], nextPageToken: nil, resultSizeEstimate: 0)
            paginatedListMessagesResponses = [:]
            getMessageResponses = [:]
            defaultGetMessageResponse = nil
            modifyMessageResponse = nil
            sendMessageResponse = SendMessageResponse(id: "sent-message-id", threadId: "sent-thread-id")
            profileResponse = GmailProfile(emailAddress: "test@example.com", messagesTotal: 100, threadsTotal: 50, historyId: "12345")
            labelsResponse = []
            sendAsResponse = []
            historyResponse = HistoryResponse(history: nil, nextPageToken: nil, historyId: "12345")
            paginatedHistoryResponses = [:]
            attachmentResponses = [:]

            // Errors
            listMessagesError = nil
            listMessagesErrorsByPageToken = [:]
            getMessageError = nil
            getMessageErrors = [:]
            modifyMessageError = nil
            sendMessageError = nil
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
            getMessageCalledFormats = []
            modifyMessageCallCount = 0
            modifyMessageCalls = []
            sendMessageCallCount = 0
            sendMessageCalls = []
            batchModifyCallCount = 0
            batchModifyCalls = []
            archiveMessagesCallCount = 0
            archiveMessagesCalledIds = []
            getProfileCallCount = 0
            listLabelsCallCount = 0
            listSendAsCallCount = 0
            listHistoryCallCount = 0
            listHistoryLastStartId = nil
            listHistoryLastPageToken = nil
            listHistoryLastMaxResults = nil
            endpointCallOrder = []
            getAttachmentCallCount = 0
            getAttachmentCalls = []

            artificialDelay = 0
        }
    }

    // MARK: - GmailAPIClientProtocol Implementation

    func listMessages(pageToken: String?, maxResults: Int, query: String?) async throws -> MessagesListResponse {
        let delay = withStateLock {
            listMessagesCallCount += 1
            listMessagesLastQuery = query
            listMessagesLastMaxResults = maxResults
            listMessagesLastPageToken = pageToken
            endpointCallOrder.append("listMessages")
            return artificialDelay
        }

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        return try withStateLock {
            if let error = listMessagesErrorsByPageToken.removeValue(forKey: pageTokenKey(pageToken)) {
                throw error
            }
            if let error = listMessagesError {
                listMessagesError = nil
                throw error
            }
            if let paginated = paginatedListMessagesResponses[pageTokenKey(pageToken)] {
                return paginated
            }
            return listMessagesResponse
        }
    }

    func getMessage(id: String, format: String) async throws -> GmailMessage {
        let delay = withStateLock {
            getMessageCallCount += 1
            getMessageCalledIds.append(id)
            getMessageCalledFormats.append(format)
            return artificialDelay
        }

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        if let error = withStateLock({ getMessageErrors[id] }) {
            throw error
        }

        if let response = try withStateLock({
            if let error = getMessageError {
                getMessageError = nil
                throw error
            }

            if let response = getMessageResponses[id] {
                return response
            }

            guard let defaultResponse = defaultGetMessageResponse else {
                return nil
            }
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
        }) {
            return response
        }

        throw APIError.notFound("Message \(id)")
    }

    func modifyMessage(id: String, addLabelIds: [String]?, removeLabelIds: [String]?) async throws -> GmailMessage {
        let delay = withStateLock {
            modifyMessageCallCount += 1
            modifyMessageCalls.append((id: id, add: addLabelIds, remove: removeLabelIds))
            return artificialDelay
        }

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        let (configuredResponse, existingMessage) = try withStateLock {
            if let error = modifyMessageError {
                modifyMessageError = nil
                throw error
            }
            return (modifyMessageResponse, getMessageResponses[id])
        }

        if let response = configuredResponse {
            return response
        }

        // Return a message with updated labels
        let existingLabels = existingMessage?.labelIds ?? []
        var newLabels = existingLabels
        if let remove = removeLabelIds {
            newLabels = newLabels.filter { !remove.contains($0) }
        }
        if let add = addLabelIds {
            newLabels.append(contentsOf: add.filter { !newLabels.contains($0) })
        }

        return GmailMessage(
            id: id,
            threadId: existingMessage?.threadId,
            labelIds: newLabels,
            snippet: existingMessage?.snippet,
            historyId: nil,
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil
        )
    }

    func sendMessage(rawMessage: String, threadId: String?) async throws -> SendMessageResponse {
        let delay = withStateLock {
            sendMessageCallCount += 1
            sendMessageCalls.append((rawMessage: rawMessage, threadId: threadId))
            return artificialDelay
        }

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        return try withStateLock {
            if let error = sendMessageError {
                sendMessageError = nil
                throw error
            }

            return sendMessageResponse
        }
    }

    func batchModify(ids: [String], addLabelIds: [String]?, removeLabelIds: [String]?) async throws {
        let delay = withStateLock {
            batchModifyCallCount += 1
            batchModifyCalls.append((ids: ids, add: addLabelIds, remove: removeLabelIds))
            return artificialDelay
        }

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        try withStateLock {
            if let error = batchModifyError {
                batchModifyError = nil
                throw error
            }
        }
    }

    func archiveMessages(ids: [String]) async throws {
        withStateLock {
            archiveMessagesCallCount += 1
            archiveMessagesCalledIds.append(ids)
        }
        try await batchModify(ids: ids, addLabelIds: nil, removeLabelIds: ["INBOX"])
    }

    func getProfile() async throws -> GmailProfile {
        let delay = withStateLock {
            getProfileCallCount += 1
            endpointCallOrder.append("getProfile")
            return artificialDelay
        }

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        return try withStateLock {
            if let error = getProfileError {
                getProfileError = nil
                throw error
            }
            return profileResponse
        }
    }

    func listLabels() async throws -> [GmailLabel] {
        let delay = withStateLock {
            listLabelsCallCount += 1
            return artificialDelay
        }

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        return try withStateLock {
            if let error = listLabelsError {
                listLabelsError = nil
                throw error
            }
            return labelsResponse
        }
    }

    func listSendAs() async throws -> [SendAs] {
        let delay = withStateLock {
            listSendAsCallCount += 1
            return artificialDelay
        }

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        return try withStateLock {
            if let error = listSendAsError {
                listSendAsError = nil
                throw error
            }
            return sendAsResponse
        }
    }

    func listHistory(startHistoryId: String, pageToken: String?, maxResults: Int?) async throws -> HistoryResponse {
        let delay = withStateLock {
            listHistoryCallCount += 1
            listHistoryLastStartId = startHistoryId
            listHistoryLastPageToken = pageToken
            listHistoryLastMaxResults = maxResults
            return artificialDelay
        }

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        return try withStateLock {
            if let error = listHistoryError {
                listHistoryError = nil
                throw error
            }
            if let paginated = paginatedHistoryResponses[pageTokenKey(pageToken)] {
                return paginated
            }
            return historyResponse
        }
    }

    func getAttachment(messageId: String, attachmentId: String) async throws -> Data {
        let delay = withStateLock {
            getAttachmentCallCount += 1
            getAttachmentCalls.append((messageId: messageId, attachmentId: attachmentId))
            return artificialDelay
        }

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        return try withStateLock {
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
}

// MARK: - Test Helpers

extension MockGmailAPIClient {
    /// Configures the mock to simulate rate limiting
    func simulateRateLimited() {
        withStateLock {
            listMessagesError = APIError.rateLimited(retryAfter: nil)
            getMessageError = APIError.rateLimited(retryAfter: nil)
        }
    }

    /// Configures the mock to simulate authentication failure
    func simulateAuthFailure() {
        withStateLock {
            listMessagesError = APIError.authenticationError
            getMessageError = APIError.authenticationError
            sendMessageError = APIError.authenticationError
            getProfileError = APIError.authenticationError
        }
    }

    /// Configures the mock to simulate server errors
    func simulateServerError(code: Int = 500) {
        withStateLock {
            listMessagesError = APIError.serverError(code)
            getMessageError = APIError.serverError(code)
        }
    }

    /// Configures the mock to simulate expired history ID
    func simulateHistoryExpired() {
        withStateLock {
            listHistoryError = APIError.historyIdExpired
        }
    }

    /// Configures the mock to simulate network timeout
    func simulateTimeout() {
        withStateLock {
            listMessagesError = APIError.timeout
            getMessageError = APIError.timeout
        }
    }

    /// Adds a message response for a specific ID
    func addMessage(_ message: GmailMessage) {
        withStateLock {
            getMessageResponses[message.id] = message
        }
    }

    /// Adds multiple message responses
    func addMessages(_ messages: [GmailMessage]) {
        withStateLock {
            for message in messages {
                getMessageResponses[message.id] = message
            }
        }
    }

    /// Configures listMessages to return the specified message IDs
    func setMessageList(_ ids: [String], threadIds: [String]? = nil) {
        let items = ids.enumerated().map { index, id in
            MessageListItem(id: id, threadId: threadIds?[safe: index])
        }
        withStateLock {
            listMessagesResponse = MessagesListResponse(messages: items, nextPageToken: nil, resultSizeEstimate: items.count)
        }
    }

    /// Configures listMessages with pagination
    func setMessageListWithPagination(_ pages: [[String]], pageTokens: [String?]) {
        guard !pages.isEmpty else { return }
        guard pageTokens.count == pages.count else {
            assertionFailure("pageTokens count must match pages count")
            return
        }

        var responses: [String: MessagesListResponse] = [:]
        var requestToken: String? = nil
        for (index, page) in pages.enumerated() {
            let items = page.map { MessageListItem(id: $0, threadId: nil) }
            let response = MessagesListResponse(
                messages: items,
                nextPageToken: pageTokens[index],
                resultSizeEstimate: page.count
            )
            responses[pageTokenKey(requestToken)] = response
            requestToken = pageTokens[index]
        }

        withStateLock {
            paginatedListMessagesResponses = responses
            if let first = responses[pageTokenKey(nil)] {
                listMessagesResponse = first
            }
        }
    }

    /// Configures listHistory with page-token keyed responses.
    /// Use nil token for the first page.
    func setHistoryResponsesByPageToken(_ responses: [(pageToken: String?, response: HistoryResponse)]) {
        var mapped: [String: HistoryResponse] = [:]
        for entry in responses {
            mapped[pageTokenKey(entry.pageToken)] = entry.response
        }
        withStateLock {
            paginatedHistoryResponses = mapped
            if let first = mapped[pageTokenKey(nil)] {
                historyResponse = first
            }
        }
    }

    /// Configures standard Gmail labels
    func setStandardLabels() {
        withStateLock {
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
}

// MARK: - Array Safe Access

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
