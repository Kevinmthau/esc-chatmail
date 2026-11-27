import Foundation
import CoreData

/// Phase 2: Fetch and persist new messages
struct MessageFetchPhase: SyncPhase {
    typealias Input = [String] // messageIds
    typealias Output = BatchProcessingResult

    let name = "Message Fetch"
    let progressRange: ClosedRange<Double> = 0.3...0.7

    private let messageFetcher: MessageFetcher
    private let messagePersister: MessagePersister
    private let log = LogCategory.sync.logger

    init(messageFetcher: MessageFetcher, messagePersister: MessagePersister) {
        self.messageFetcher = messageFetcher
        self.messagePersister = messagePersister
    }

    func execute(
        input messageIds: [String],
        context: SyncPhaseContext
    ) async throws -> BatchProcessingResult {
        guard !messageIds.isEmpty else {
            log.debug("No new messages to fetch")
            return BatchProcessingResult(totalProcessed: 0, successfulCount: 0, failedIds: [])
        }

        log.info("Fetching \(messageIds.count) new messages")
        if !context.allowsIntermediateContextSaves {
            log.debug("Deferring message-fetch batch saves because history may delete local messages")
        }

        let result = try await BatchProcessor.processMessages(
            messageIds: messageIds,
            batchSize: SyncConfig.messageBatchSize,
            messageFetcher: messageFetcher
        ) { processed, total in
            let progress = Double(processed) / Double(total)
            await MainActor.run {
                context.reportProgress(progress, status: "Processing messages... \(processed)/\(total)", phase: self)
            }
        } messageHandler: { [messagePersister] messages in
            try await messagePersister.saveMessages(
                messages,
                labelIds: context.labelIds,
                myAliases: context.myAliases,
                sendAsAliases: context.sendAsAliases,
                modificationTransaction: context.modificationTransaction,
                in: context.coreDataContext
            )
        } batchCompletion: {
            guard context.allowsIntermediateContextSaves else { return }
            try await context.coreDataContext.perform {
                guard context.coreDataContext.hasChanges else { return }
                try context.coreDataContext.save()
            }
        }

        if result.hasFailures {
            log.warning(
                "\(result.failedIds.count) messages failed to fetch, \(result.persistence.failedIds.count) failed to persist"
            )
            // Staged into the sync context, not saved here. The deferred ledger rows
            // commit at the orchestrator's next save point: the intermediate flush
            // where the run admits one (`allowsIntermediateContextSaves`, the batch
            // completion above and the rollup flush after label processing), else
            // the final save. Either way they commit ahead of the strike the final
            // save stages, and the cursor is staged only at that final save.
            await context.failureTracker.recordFailure(
                fetchFailedIds: result.failedIds,
                persistenceFailedIds: result.persistence.failedIds,
                sourceHistoryId: context.sourceHistoryId,
                in: context.coreDataContext
            )
        }

        return result
    }
}
