import Foundation

// Note: SyncConfig is defined in Constants.swift

/// Result of a bounded concurrency fetch operation
private struct BoundedFetchResult {
    let successfulMessages: [GmailMessage]
    let retriableFailedIds: [String]
    /// Messages that failed with non-retriable errors (4xx client errors, not found, etc.)
    let permanentlyFailedIds: [String]
    /// Messages that failed with retriable errors but we've exhausted retries
    /// These might succeed on a future sync attempt
    let exhaustedRetryIds: [String]
}

/// Handles fetching messages from the Gmail API with retry logic and timeout handling
final class MessageFetcher: @unchecked Sendable {
    private let apiClient: GmailAPIClient

    /// Maximum number of retry attempts for failed messages
    private let maxRetryAttempts = 3

    /// Base delay in nanoseconds for exponential backoff (500ms)
    private let baseRetryDelay: UInt64 = 500_000_000

    @MainActor init() {
        self.apiClient = GmailAPIClient.shared
    }

    /// Checks if an error is retriable (transient network/server issues)
    private func isRetriableError(_ error: Error) -> Bool {
        // URLError codes that are retriable
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }

        // API errors that are retriable
        if let apiError = error as? APIError {
            switch apiError {
            case .rateLimited, .timeout, .serverError:
                return true
            case .authenticationError, .historyIdExpired, .notFound:
                return false
            default:
                // Default to non-retriable for unknown API errors to avoid infinite retry loops
                return false
            }
        }

        // NSError timeout codes using URLError constants for clarity
        if let nsError = error as NSError? {
            if nsError.domain == NSURLErrorDomain {
                // Map error codes to URLError equivalents for clarity:
                // -1001 = .timedOut, -1009 = .notConnectedToInternet,
                // -1004 = .cannotConnectToHost, -1005 = .networkConnectionLost
                return [URLError.timedOut.rawValue, URLError.notConnectedToInternet.rawValue,
                        URLError.cannotConnectToHost.rawValue, URLError.networkConnectionLost.rawValue].contains(nsError.code)
            }
        }

        // Default to non-retriable for unknown errors to avoid infinite retry loops
        return false
    }

    /// Fetches messages with bounded concurrency to prevent resource exhaustion.
    /// - Parameters:
    ///   - ids: Array of message IDs to fetch
    ///   - isFinalAttempt: If true, retriable failures go to exhaustedRetryIds instead of retriableFailedIds
    /// - Returns: Result containing successful messages and categorized failures
    private func fetchWithBoundedConcurrency(
        ids: [String],
        isFinalAttempt: Bool = false
    ) async -> BoundedFetchResult {
        var successfulMessages: [GmailMessage] = []
        var retriableFailedIds: [String] = []
        var permanentlyFailedIds: [String] = []
        var exhaustedRetryIds: [String] = []

        await withTaskGroup(of: (String, Result<GmailMessage, Error>).self) { group in
            var iterator = ids.makeIterator()
            var activeTasks = 0
            let maxConcurrent = SyncConfig.maxConcurrentMessageFetches

            // Start initial batch of concurrent tasks
            while activeTasks < maxConcurrent, let id = iterator.next() {
                group.addTask { [apiClient] in
                    // Check cancellation at start of child task to propagate cancellation quickly
                    do {
                        try Task.checkCancellation()
                        let message = try await withTimeout(seconds: SyncConfig.messageFetchTimeout) {
                            try await apiClient.getMessage(id: id)
                        }
                        return (id, .success(message))
                    } catch {
                        return (id, .failure(error))
                    }
                }
                activeTasks += 1
            }

            // Process results and start new tasks as others complete
            for await (id, result) in group {
                if Task.isCancelled {
                    // Cancel all remaining child tasks when parent is cancelled
                    group.cancelAll()
                    break
                }

                activeTasks -= 1

                switch result {
                case .success(let message):
                    successfulMessages.append(message)
                case .failure(let error):
                    if self.isRetriableError(error) {
                        // Transient error (timeout, network, 5xx)
                        if isFinalAttempt {
                            // We've exhausted retries, but this might succeed on future sync
                            exhaustedRetryIds.append(id)
                        } else {
                            retriableFailedIds.append(id)
                        }
                    } else {
                        // Non-retriable error (4xx, auth, not found) - truly permanent
                        permanentlyFailedIds.append(id)
                    }
                }

                // Start next task if there are more IDs
                if let nextId = iterator.next() {
                    group.addTask { [apiClient] in
                        // Check cancellation at start of child task to propagate cancellation quickly
                        do {
                            try Task.checkCancellation()
                            let message = try await withTimeout(seconds: SyncConfig.messageFetchTimeout) {
                                try await apiClient.getMessage(id: nextId)
                            }
                            return (nextId, .success(message))
                        } catch {
                            return (nextId, .failure(error))
                        }
                    }
                    activeTasks += 1
                }
            }
        }

        return BoundedFetchResult(
            successfulMessages: successfulMessages,
            retriableFailedIds: retriableFailedIds,
            permanentlyFailedIds: permanentlyFailedIds,
            exhaustedRetryIds: exhaustedRetryIds
        )
    }

    /// Sorts messages by internalDate and invokes callback for each in chronological order.
    private func persistInChronologicalOrder(
        _ messages: [GmailMessage],
        onSuccess: @escaping @Sendable (GmailMessage) async -> Void
    ) async {
        // internalDate is milliseconds since epoch as a string; nil sorts to beginning
        let sortedMessages = messages.sorted {
            ($0.internalDate ?? "0") < ($1.internalDate ?? "0")
        }
        for message in sortedMessages {
            await onSuccess(message)
        }
    }

    /// Fetches a batch of messages by ID with automatic retry on failure
    /// - Parameters:
    ///   - ids: Array of Gmail message IDs to fetch
    ///   - onSuccess: Callback for each successfully fetched message
    /// - Returns: Array of message IDs that permanently failed to fetch (non-retriable errors only)
    func fetchBatch(
        _ ids: [String],
        onSuccess: @escaping @Sendable (GmailMessage) async -> Void
    ) async -> [String] {
        guard !Task.isCancelled else {
            Log.debug("Batch processing cancelled", category: .sync)
            return ids
        }

        var permanentlyFailed: [String] = []
        var exhaustedRetries: [String] = []

        // First attempt
        let initialResult = await fetchWithBoundedConcurrency(ids: ids)
        permanentlyFailed.append(contentsOf: initialResult.permanentlyFailedIds)

        for id in initialResult.permanentlyFailedIds {
            Log.warning("Non-retriable error for message \(id)", category: .sync)
        }

        await persistInChronologicalOrder(initialResult.successfulMessages, onSuccess: onSuccess)

        var currentFailedIds = initialResult.retriableFailedIds

        // Retry loop with exponential backoff and jitter
        for attempt in 1...maxRetryAttempts {
            guard !Task.isCancelled, !currentFailedIds.isEmpty else {
                break
            }

            // Exponential backoff with jitter to prevent thundering herd
            let delay = calculateRetryDelay(attempt: attempt)
            Log.debug("Retry attempt \(attempt)/\(maxRetryAttempts) for \(currentFailedIds.count) failed messages after \(delay / 1_000_000)ms...", category: .sync)

            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                // Task was cancelled during sleep
                break
            }

            guard !Task.isCancelled else { break }

            let isFinalAttempt = attempt == maxRetryAttempts
            let retryResult = await fetchWithBoundedConcurrency(ids: currentFailedIds, isFinalAttempt: isFinalAttempt)

            for message in retryResult.successfulMessages {
                Log.debug("Successfully fetched message \(message.id) on retry attempt \(attempt)", category: .sync)
            }

            for id in retryResult.permanentlyFailedIds {
                Log.warning("Permanently failed to fetch message \(id) after \(attempt) attempts", category: .sync)
            }

            permanentlyFailed.append(contentsOf: retryResult.permanentlyFailedIds)
            exhaustedRetries.append(contentsOf: retryResult.exhaustedRetryIds)
            await persistInChronologicalOrder(retryResult.successfulMessages, onSuccess: onSuccess)

            currentFailedIds = retryResult.retriableFailedIds
        }

        // Log exhausted retries separately - these might succeed on next sync
        if !exhaustedRetries.isEmpty {
            Log.info("Messages with transient failures after \(maxRetryAttempts) retries (may succeed on next sync): \(exhaustedRetries.count)", category: .sync)
        }

        // Only return truly permanently failed messages (non-retriable errors)
        // Exhausted retries are NOT included - they may succeed on next sync attempt
        if !permanentlyFailed.isEmpty {
            Log.warning("Total permanently failed messages (non-retriable errors): \(permanentlyFailed.count)", category: .sync)
        }

        return permanentlyFailed
    }

    /// Fetches messages from Gmail API using pagination
    /// - Parameters:
    ///   - query: Gmail search query
    ///   - pageToken: Optional page token for pagination
    ///   - maxResults: Maximum number of results per page
    /// - Returns: Tuple of message IDs and next page token (if any)
    func listMessages(
        query: String,
        pageToken: String? = nil,
        maxResults: Int = SyncConfig.maxMessagesPerRequest
    ) async throws -> (messageIds: [String], nextPageToken: String?) {
        let response = try await apiClient.listMessages(
            pageToken: pageToken,
            maxResults: maxResults,
            query: query
        )

        let messageIds = response.messages?.map { $0.id } ?? []
        return (messageIds, response.nextPageToken)
    }

    /// Fetches history records from Gmail API
    /// - Parameters:
    ///   - startHistoryId: Starting history ID
    ///   - pageToken: Optional page token for pagination
    /// - Returns: Tuple of history records, latest history ID, and next page token
    func listHistory(
        startHistoryId: String,
        pageToken: String? = nil
    ) async throws -> (history: [HistoryRecord]?, historyId: String?, nextPageToken: String?) {
        let response = try await apiClient.listHistory(
            startHistoryId: startHistoryId,
            pageToken: pageToken
        )

        return (response.history, response.historyId, response.nextPageToken)
    }

    /// Fetches user profile from Gmail API
    func getProfile() async throws -> GmailProfile {
        return try await apiClient.getProfile()
    }

    /// Fetches send-as aliases from Gmail API
    func listSendAs() async throws -> [SendAs] {
        return try await apiClient.listSendAs()
    }

    /// Fetches all labels from Gmail API
    func listLabels() async throws -> [GmailLabel] {
        return try await apiClient.listLabels()
    }

    // MARK: - Private Helpers

    /// Calculates retry delay with exponential backoff and jitter to prevent thundering herd.
    ///
    /// Jitter adds 0-25% randomness to the base delay, spreading out retry attempts
    /// when multiple operations fail simultaneously.
    ///
    /// - Parameter attempt: The current retry attempt number (1-based)
    /// - Returns: Delay in nanoseconds
    private func calculateRetryDelay(attempt: Int) -> UInt64 {
        // Base exponential backoff: 500ms, 1s, 2s, etc.
        let baseDelay = baseRetryDelay * UInt64(1 << (attempt - 1))

        // Add 0-25% jitter to prevent thundering herd
        let jitter = UInt64.random(in: 0...(baseDelay / 4))

        return baseDelay + jitter
    }
}
// Note: withTimeout function is defined in GmailAPIClient.swift
