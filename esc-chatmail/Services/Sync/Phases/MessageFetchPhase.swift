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

        let result = try await BatchProcessor.processMessages(
            messageIds: messageIds,
            batchSize: SyncConfig.messageBatchSize,
            messageFetcher: messageFetcher
        ) { processed, total in
            let progress = Double(processed) / Double(total)
            await MainActor.run {
                context.reportProgress(progress, status: "Processing messages... \(processed)/\(total)", phase: self)
            }
        } messageHandler: { [messagePersister] message in
            await messagePersister.saveMessage(
                message,
                labelIds: context.labelIds,
                myAliases: context.myAliases,
                in: context.coreDataContext
            )
        }

        if result.hasFailures {
            log.warning("\(result.failedIds.count) messages failed to fetch")
            await context.failureTracker.recordFailure(failedIds: result.failedIds)
        }

        return result
    }
}
