import Foundation

// Note: SyncConfig is defined in Constants.swift

/// Handles fetching messages from the Gmail API with retry logic and timeout handling
@MainActor
final class MessageFetcher {
    private let apiClient: GmailAPIClient

    /// Maximum number of retry attempts for failed messages
    private let maxRetryAttempts = 3

    /// Base delay in nanoseconds for exponential backoff (500ms)
    private let baseRetryDelay: UInt64 = 500_000_000

    init() {
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
                return true // Default to retriable for unknown API errors
            }
        }

        // NSError timeout codes
        if let nsError = error as NSError? {
            if nsError.domain == NSURLErrorDomain {
                return [-1001, -1009, -1004, -1005].contains(nsError.code) // timeout, not connected, can't connect, connection lost
            }
        }

        return true // Default to retriable for unknown errors
    }

    /// Fetches a batch of messages by ID with automatic retry on failure
    /// - Parameters:
    ///   - ids: Array of Gmail message IDs to fetch
    ///   - onSuccess: Callback for each successfully fetched message
    /// - Returns: Array of message IDs that permanently failed to fetch
    func fetchBatch(
        _ ids: [String],
        onSuccess: @escaping @Sendable (GmailMessage) async -> Void
    ) async -> [String] {
        guard !Task.isCancelled else {
            Log.debug("Batch processing cancelled", category: .sync)
            return ids
        }

        var currentFailedIds: [String] = []
        var permanentlyFailed: [String] = []

        // First attempt with timeout per message
        await withTaskGroup(of: (String, Result<GmailMessage, Error>).self) { group in
            for id in ids {
                group.addTask { [apiClient] in
                    do {
                        let message = try await withTimeout(seconds: SyncConfig.messageFetchTimeout) {
                            try await apiClient.getMessage(id: id)
                        }
                        return (id, .success(message))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }

            for await (id, result) in group {
                if Task.isCancelled { break }

                switch result {
                case .success(let message):
                    await onSuccess(message)
                case .failure(let error):
                    if self.isRetriableError(error) {
                        currentFailedIds.append(id)
                    } else {
                        Log.warning("Non-retriable error for message \(id): \(error.localizedDescription)", category: .sync)
                        permanentlyFailed.append(id)
                    }
                }
            }
        }

        // Retry loop with exponential backoff
        for attempt in 1...maxRetryAttempts {
            guard !Task.isCancelled, !currentFailedIds.isEmpty else {
                break
            }

            // Exponential backoff: 500ms, 1s, 2s
            let delay = baseRetryDelay * UInt64(1 << (attempt - 1))
            Log.debug("Retry attempt \(attempt)/\(maxRetryAttempts) for \(currentFailedIds.count) failed messages after \(delay / 1_000_000)ms...", category: .sync)

            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                // Task was cancelled during sleep
                break
            }

            guard !Task.isCancelled else { break }

            var stillFailed: [String] = []

            await withTaskGroup(of: (String, Result<GmailMessage, Error>).self) { group in
                for id in currentFailedIds {
                    group.addTask { [apiClient] in
                        do {
                            let message = try await withTimeout(seconds: SyncConfig.messageFetchTimeout) {
                                try await apiClient.getMessage(id: id)
                            }
                            return (id, .success(message))
                        } catch {
                            return (id, .failure(error))
                        }
                    }
                }

                for await (id, result) in group {
                    if Task.isCancelled { break }

                    switch result {
                    case .success(let message):
                        await onSuccess(message)
                        Log.debug("Successfully fetched message \(id) on retry attempt \(attempt)", category: .sync)
                    case .failure(let error):
                        if attempt == maxRetryAttempts || !self.isRetriableError(error) {
                            // Final attempt or non-retriable error
                            Log.warning("Permanently failed to fetch message \(id) after \(attempt) attempts: \(error.localizedDescription)", category: .sync)
                            permanentlyFailed.append(id)
                        } else {
                            stillFailed.append(id)
                        }
                    }
                }
            }

            currentFailedIds = stillFailed
        }

        // Any remaining failed IDs should be added to permanently failed
        permanentlyFailed.append(contentsOf: currentFailedIds)

        if !permanentlyFailed.isEmpty {
            Log.warning("Total permanently failed messages: \(permanentlyFailed.count)", category: .sync)
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
}
// Note: withTimeout function is defined in GmailAPIClient.swift
