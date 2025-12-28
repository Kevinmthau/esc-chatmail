import Foundation

/// Result of batch processing operations
struct BatchProcessingResult {
    let totalProcessed: Int
    let successfulCount: Int
    let failedIds: [String]

    var hasFailures: Bool { !failedIds.isEmpty }
}

/// Utility for processing items in batches with progress tracking
/// Eliminates duplicate batch processing code in SyncEngine
struct BatchProcessor {

    /// Processes message IDs in batches, calling the handler for each successfully fetched message
    /// - Parameters:
    ///   - messageIds: All message IDs to process
    ///   - batchSize: Size of each batch
    ///   - messageFetcher: The fetcher to use for batch retrieval
    ///   - progressHandler: Called after each batch with (processedCount, totalCount)
    ///   - messageHandler: Called for each successfully fetched message
    /// - Returns: BatchProcessingResult with success/failure counts
    static func processMessages(
        messageIds: [String],
        batchSize: Int,
        messageFetcher: MessageFetcher,
        progressHandler: @escaping (Int, Int) async -> Void,
        messageHandler: @escaping (GmailMessage) async -> Void
    ) async throws -> BatchProcessingResult {
        var totalProcessed = 0
        var totalSuccessful = 0
        var allFailedIds: [String] = []

        for batch in messageIds.chunked(into: batchSize) {
            try Task.checkCancellation()

            let failedIds = await messageFetcher.fetchBatch(batch) { message in
                await messageHandler(message)
            }

            let successCount = batch.count - failedIds.count
            totalSuccessful += successCount
            allFailedIds.append(contentsOf: failedIds)
            totalProcessed += batch.count

            await progressHandler(totalProcessed, messageIds.count)
        }

        return BatchProcessingResult(
            totalProcessed: totalProcessed,
            successfulCount: totalSuccessful,
            failedIds: allFailedIds
        )
    }

    /// Retries fetching failed message IDs
    /// - Parameters:
    ///   - failedIds: IDs that failed in the initial attempt
    ///   - messageFetcher: The fetcher to use
    ///   - messageHandler: Handler for successfully fetched messages
    /// - Returns: IDs that still failed after retry
    static func retryFailedMessages(
        failedIds: [String],
        messageFetcher: MessageFetcher,
        messageHandler: @escaping (GmailMessage) async -> Void
    ) async -> [String] {
        guard !failedIds.isEmpty else { return [] }

        Log.debug("Retrying \(failedIds.count) failed messages...", category: .sync)

        let stillFailedIds = await messageFetcher.fetchBatch(failedIds) { message in
            await messageHandler(message)
        }

        if stillFailedIds.isEmpty {
            Log.debug("All failed messages recovered on retry", category: .sync)
        } else {
            Log.warning("\(stillFailedIds.count) messages permanently failed", category: .sync)
        }

        return stillFailedIds
    }
}
