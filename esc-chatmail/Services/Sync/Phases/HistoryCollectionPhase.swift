import Foundation

/// Phase 1: Collect all history changes since last sync
struct HistoryCollectionPhase: SyncPhase {
    typealias Input = String // startHistoryId
    typealias Output = HistoryCollectionResult

    let name = "History Collection"
    let progressRange: ClosedRange<Double> = 0.0...0.1

    private let messageFetcher: MessageFetcher
    private let historyProcessor: HistoryProcessor
    private let log = LogCategory.sync.logger

    /// Maximum number of history pages to fetch to prevent unbounded memory growth
    /// If exceeded, sync will continue with partial data (next sync will catch remaining)
    private let maxHistoryPages = 50

    init(messageFetcher: MessageFetcher, historyProcessor: HistoryProcessor) {
        self.messageFetcher = messageFetcher
        self.historyProcessor = historyProcessor
    }

    func execute(
        input startHistoryId: String,
        context: SyncPhaseContext
    ) async throws -> HistoryCollectionResult {
        context.reportProgress(0, status: "Fetching history...", phase: self)

        var pageToken: String? = nil
        var latestHistoryId = startHistoryId
        var allNewMessageIds: Set<String> = []
        var allHistoryRecords: [HistoryRecord] = []
        var pageCount = 0

        repeat {
            try Task.checkCancellation()

            let (history, newHistoryId, nextPageToken) = try await messageFetcher.listHistory(
                startHistoryId: startHistoryId,
                pageToken: pageToken
            )

            if let history = history, !history.isEmpty {
                log.debug("Received \(history.count) history records")
                let newIds = historyProcessor.extractNewMessageIds(from: history)
                allNewMessageIds.formUnion(newIds)
                allHistoryRecords.append(contentsOf: history)
            }

            if let newHistoryId = newHistoryId {
                latestHistoryId = newHistoryId
            }

            pageToken = nextPageToken
            pageCount += 1

            // Prevent unbounded memory growth by limiting pages
            if pageCount >= maxHistoryPages && pageToken != nil {
                log.warning("History collection reached page limit (\(maxHistoryPages)). Partial sync will continue; next sync will catch remaining changes.")
                break
            }
        } while pageToken != nil

        log.info("History collection: \(allNewMessageIds.count) unique messages, \(allHistoryRecords.count) records")

        context.reportProgress(1.0, status: "History collected", phase: self)

        return HistoryCollectionResult(
            newMessageIds: Array(allNewMessageIds),
            records: allHistoryRecords,
            latestHistoryId: latestHistoryId
        )
    }
}
