import Foundation

// Note: SyncConfig is defined in Constants.swift

/// Handles fetching messages from the Gmail API with retry logic and timeout handling
@MainActor
final class MessageFetcher {
    private let apiClient: GmailAPIClient

    init() {
        self.apiClient = GmailAPIClient.shared
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
            print("Batch processing cancelled")
            return ids
        }

        var failedIds: [String] = []

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
                        print("Failed to fetch message \(id): \(error.localizedDescription)")
                        return (id, .failure(error))
                    }
                }
            }

            for await (id, result) in group {
                if Task.isCancelled { break }

                switch result {
                case .success(let message):
                    await onSuccess(message)
                case .failure:
                    failedIds.append(id)
                }
            }
        }

        // Check for cancellation before retry
        guard !Task.isCancelled, !failedIds.isEmpty else {
            return failedIds
        }

        // Retry failed messages once with backoff
        print("Retrying \(failedIds.count) failed messages...")
        try? await Task.sleep(nanoseconds: SyncConfig.retryDelaySeconds)

        guard !Task.isCancelled else { return failedIds }

        var permanentlyFailed: [String] = []

        await withTaskGroup(of: (String, Result<GmailMessage, Error>).self) { group in
            for id in failedIds {
                group.addTask { [apiClient] in
                    do {
                        let message = try await withTimeout(seconds: SyncConfig.messageFetchTimeout) {
                            try await apiClient.getMessage(id: id)
                        }
                        return (id, .success(message))
                    } catch {
                        print("Retry failed for message \(id): \(error.localizedDescription)")
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
                    print("Permanently failed to fetch message \(id): \(error.localizedDescription)")
                    permanentlyFailed.append(id)
                }
            }
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
