import Foundation

/// Handles paginated message list fetching from Gmail API
///
/// Eliminates duplicate pagination loops in:
/// - InitialSyncOrchestrator.fetchAndProcessMessages()
/// - IncrementalSyncOrchestrator.performHistoryRecoverySync()
struct MessageListPaginator {

    /// Fetches all message IDs matching a query, handling pagination automatically
    ///
    /// - Parameters:
    ///   - query: Gmail search query (e.g., "after:1234567890 -label:spam -label:drafts")
    ///   - messageFetcher: The fetcher to use for API calls
    /// - Returns: Array of all message IDs matching the query
    /// - Throws: Cancellation errors if task is cancelled, or API errors
    static func fetchAllMessageIds(
        query: String,
        using messageFetcher: MessageFetcher
    ) async throws -> [String] {
        var pageToken: String? = nil
        var allMessageIds: [String] = []

        repeat {
            try Task.checkCancellation()
            let (messageIds, nextPageToken) = try await messageFetcher.listMessages(
                query: query,
                pageToken: pageToken
            )
            allMessageIds.append(contentsOf: messageIds)
            pageToken = nextPageToken
        } while pageToken != nil

        return allMessageIds
    }

    /// Fetches and processes all messages matching a query with progress tracking
    ///
    /// Combines pagination + batch processing into a single operation.
    /// Uses `BatchProcessor.processMessages` internally for efficient batch retrieval.
    ///
    /// - Parameters:
    ///   - query: Gmail search query
    ///   - messageFetcher: The fetcher to use for API calls
    ///   - progressHandler: Called after each batch with (processedCount, totalCount)
    ///   - messageHandler: Called for each successfully fetched message
    /// - Returns: BatchProcessingResult with success/failure counts
    /// - Throws: Cancellation errors or API errors
    static func fetchAndProcess(
        query: String,
        messageFetcher: MessageFetcher,
        progressHandler: @escaping (Int, Int) async -> Void,
        messageHandler: @escaping (GmailMessage) async -> Void
    ) async throws -> BatchProcessingResult {
        let allMessageIds = try await fetchAllMessageIds(query: query, using: messageFetcher)

        return try await BatchProcessor.processMessages(
            messageIds: allMessageIds,
            batchSize: SyncConfig.messageBatchSize,
            messageFetcher: messageFetcher,
            progressHandler: progressHandler,
            messageHandler: messageHandler
        )
    }

    /// Fetches and processes messages with a custom batch size
    ///
    /// - Parameters:
    ///   - query: Gmail search query
    ///   - batchSize: Number of messages to process per batch
    ///   - messageFetcher: The fetcher to use for API calls
    ///   - progressHandler: Called after each batch with (processedCount, totalCount)
    ///   - messageHandler: Called for each successfully fetched message
    /// - Returns: BatchProcessingResult with success/failure counts
    static func fetchAndProcess(
        query: String,
        batchSize: Int,
        messageFetcher: MessageFetcher,
        progressHandler: @escaping (Int, Int) async -> Void,
        messageHandler: @escaping (GmailMessage) async -> Void
    ) async throws -> BatchProcessingResult {
        let allMessageIds = try await fetchAllMessageIds(query: query, using: messageFetcher)

        return try await BatchProcessor.processMessages(
            messageIds: allMessageIds,
            batchSize: batchSize,
            messageFetcher: messageFetcher,
            progressHandler: progressHandler,
            messageHandler: messageHandler
        )
    }
}
