import Foundation

// MARK: - Messages API

extension GmailAPIClient {

    /// Lists messages in the mailbox.
    nonisolated func listMessages(pageToken: String? = nil, maxResults: Int = 100, query: String? = nil) async throws -> MessagesListResponse {
        var queryItems = [URLQueryItem(name: "maxResults", value: String(maxResults))]
        if let pageToken = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if let query = query {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        return try await performGET(endpoint: APIEndpoints.messages(), queryItems: queryItems)
    }

    /// One page of a search over every label, Spam and Trash included.
    nonisolated func searchAllMessages(query: String, maxResults: Int) async throws -> MessagesListResponse {
        let queryItems = [
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "includeSpamTrash", value: "true")
        ]
        return try await performGET(endpoint: APIEndpoints.messages(), queryItems: queryItems)
    }

    /// Fetches a single message by ID.
    nonisolated func getMessage(id: String, format: String = "full") async throws -> GmailMessage {
        try await getMessage(id: id, format: format, maxRetries: nil)
    }

    /// Retry-budgeted fetch: threads `maxRetries` (total attempts; nil = the
    /// configured strategy) into the retry loop so callers owning their own
    /// retry policy (MessageFetcher) can collapse the stacked loops.
    nonisolated func getMessage(id: String, format: String, maxRetries: Int?) async throws -> GmailMessage {
        let url = try buildURL(
            endpoint: APIEndpoints.message(id: id),
            queryItems: [URLQueryItem(name: "format", value: format)]
        )
        let request = try await authenticatedRequest(url: url)
        return try await performRequestWithRetry(request, maxRetries: maxRetries)
    }

    /// Modifies a message's labels.
    nonisolated func modifyMessage(id: String, addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) async throws -> GmailMessage {
        let url = try buildURL(endpoint: APIEndpoints.modifyMessage(id: id))
        var request = try await authenticatedRequest(url: url)
        request.httpMethod = "POST"

        let body = ModifyMessageRequest(addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
        request.httpBody = try JSONEncoder().encode(body)

        return try await performRequestWithRetry(request)
    }

    /// Batch modifies multiple messages.
    nonisolated func batchModify(ids: [String], addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) async throws {
        let url = try buildURL(endpoint: APIEndpoints.batchModify())
        var request = try await authenticatedRequest(url: url)
        request.httpMethod = "POST"

        let body = BatchModifyRequest(ids: ids, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
        request.httpBody = try JSONEncoder().encode(body)

        let _: EmptyResponse = try await performRequestWithRetry(request)
    }

    /// Sends one message: `mimeData` is its RFC 822 bytes, not base64.
    ///
    /// The body goes to messages.send's upload endpoint (`uploadType=multipart`),
    /// streamed from a file (`GmailMultipartSendUpload`), not as one in-memory
    /// base64-in-JSON body: that body was about 4/3 of the MIME, and three or four
    /// photos on cellular ran past the send's 300 s cap after the barrier into
    /// "Delivery unknown". Only the transport of the body changed: the barrier, the
    /// send session and the no-retransmission rules are as they were.
    nonisolated func sendMessage(
        mimeData: Data,
        threadId: String? = nil,
        beforeTransmission: @Sendable () async throws -> Void = {}
    ) async throws -> SendMessageResponse {
        let request: URLRequest
        let upload: GmailMultipartSendUpload
        do {
            let url = try buildURL(
                endpoint: APIEndpoints.sendMessageUpload(),
                queryItems: [URLQueryItem(name: "uploadType", value: "multipart")]
            )
            var preparedRequest = try await authenticatedRequest(url: url)
            preparedRequest.httpMethod = "POST"

            // The body file is written before the barrier: a write that fails
            // (a full disk) proves nothing reached Gmail.
            let written = try GmailMultipartSendUpload.write(
                mimeData: mimeData,
                threadId: threadId,
                in: sendUploadDirectory
            )
            preparedRequest.setValue(written.contentType, forHTTPHeaderField: "Content-Type")

            // This is the final safe boundary: authentication and request-body
            // construction are complete, but URLSession has not admitted the
            // first non-idempotent request yet.
            do {
                try Task.checkCancellation()
                try await beforeTransmission()
            } catch {
                written.remove()
                throw error
            }
            request = preparedRequest
            upload = written
        } catch {
            throw GmailMessageSendError.transmissionNotStarted(error)
        }
        // Every attempt (a retry after a 401, a 429 or a pre-transmission
        // failure) uploads the same file, so it is removed only once the
        // whole send has ended.
        defer { upload.remove() }

        // Sending is not idempotent and Gmail has no idempotency key: resending after
        // an ambiguous failure (timeout, 5xx) could deliver the email twice. Preserve
        // that distinction for the optimistic-send recovery layer instead of reducing
        // it to an ordinary API failure that would enable a duplicate retry.
        //
        // `sendSession` does not wait for connectivity, so an offline send fails at
        // once with a pre-transmission error (definite "Not sent") rather than
        // waiting out the resource timeout into an ambiguous one.
        do {
            return try await performRequestWithRetry(
                request,
                allowsRetransmission: false,
                session: sendSession,
                uploadingBodyFrom: upload.fileURL
            )
        } catch {
            if Self.isAmbiguousSendFailure(error) {
                throw GmailMessageSendError.ambiguousDelivery(error)
            }
            throw error
        }
    }

    private nonisolated static func isAmbiguousSendFailure(_ error: Error) -> Bool {
        if error is GmailAPIClient.RetryCancelledBeforeRetransmission {
            return false
        }

        if error is CancellationError {
            return true
        }

        if let apiError = error as? APIError {
            switch apiError {
            case .serverError, .timeout, .decodingError:
                return true
            case .networkError(let underlying):
                return !ConnectionErrorDetector.isPreTransmissionError(underlying)
            default:
                // Authentication, rate/quota rejection, malformed requests,
                // and other client responses prove Gmail did not commit send.
                return false
            }
        }

        // Connection-establishment failures prove no application bytes reached
        // Gmail. Other transport failures (timeout, reset, malformed response)
        // cannot establish whether Gmail committed the request.
        return !ConnectionErrorDetector.isPreTransmissionError(error)
    }

    /// Archives messages by removing the INBOX label.
    nonisolated func archiveMessages(ids: [String]) async throws {
        try await batchModify(ids: ids, removeLabelIds: ["INBOX"])
    }
}
