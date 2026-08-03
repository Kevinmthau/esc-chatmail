import Foundation

/// Result of batch processing operations. `successfulCount` counts messages
/// that actually reached the persistence layer as persisted — not merely
/// fetched. `failedIds` are blocking fetch failures; persistence failures ride
/// in `persistence.failedIds`; both gate cursor advancement via `hasFailures`.
struct BatchProcessingResult {
    let totalProcessed: Int
    let successfulCount: Int
    let failedIds: [String]
    var goneIds: [String] = []
    var persistence: MessagePersistenceReport = .empty

    var hasFailures: Bool { !failedIds.isEmpty || !persistence.failedIds.isEmpty }

    /// Every ID whose outcome must prevent the history cursor from advancing.
    var blockingFailureIds: [String] { failedIds + persistence.failedIds }
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
    ///   - messageHandler: Called with each successfully fetched group of messages,
    ///     sorted into chronological order
    /// - Returns: BatchProcessingResult with success/failure counts
    static func processMessages(
        messageIds: [String],
        batchSize: Int,
        messageFetcher: MessageFetcher,
        progressHandler: @escaping (Int, Int) async -> Void,
        messageHandler: @escaping @Sendable ([GmailMessage]) async throws -> MessagePersistenceReport,
        batchCompletion: (() async throws -> Void)? = nil
    ) async throws -> BatchProcessingResult {
        var totalProcessed = 0
        var allFailedIds: [String] = []
        var allGoneIds: [String] = []
        var persistence = MessagePersistenceReport()

        for batch in messageIds.chunked(into: batchSize) {
            try Task.checkCancellation()

            // Quota exhaustion propagates and aborts the remaining chunks:
            // they would all fail identically, and per-message verdicts must
            // not be recorded for an account-scoped condition.
            let outcome = try await messageFetcher.fetchBatch(batch) { messages in
                try await messageHandler(messages)
            }

            allFailedIds.append(contentsOf: outcome.fetchFailedIds)
            allGoneIds.append(contentsOf: outcome.goneIds)
            persistence.merge(outcome.persistence)
            totalProcessed += batch.count

            await progressHandler(totalProcessed, messageIds.count)
            if let batchCompletion {
                try await batchCompletion()
            }
        }

        return BatchProcessingResult(
            totalProcessed: totalProcessed,
            successfulCount: persistence.persistedIds.count,
            failedIds: allFailedIds,
            goneIds: allGoneIds,
            persistence: persistence
        )
    }

    /// Retries fetching failed message IDs
    /// - Parameters:
    ///   - failedIds: IDs that failed in the initial attempt
    ///   - messageFetcher: The fetcher to use
    ///   - messageHandler: Handler for successfully fetched groups of messages,
    ///     sorted into chronological order; returns the persistence report
    /// - Returns: The retry outcome (blocking failures, gone IDs, persistence report)
    /// - Throws: `APIError.quotaExhausted` — the run must abort rather than
    ///   record the remaining IDs as failures
    static func retryFailedMessages(
        failedIds: [String],
        messageFetcher: MessageFetcher,
        messageHandler: @escaping @Sendable ([GmailMessage]) async throws -> MessagePersistenceReport
    ) async throws -> MessageBatchOutcome {
        guard !failedIds.isEmpty else { return .empty }

        Log.debug("Retrying \(failedIds.count) failed messages...", category: .sync)

        let outcome = try await messageFetcher.fetchBatch(failedIds) { messages in
            try await messageHandler(messages)
        }

        if outcome.hasBlockingFailures {
            Log.warning("\(outcome.blockingFailureIds.count) messages still failed after retry", category: .sync)
        } else {
            Log.debug("All failed messages recovered on retry", category: .sync)
        }

        return outcome
    }
}
