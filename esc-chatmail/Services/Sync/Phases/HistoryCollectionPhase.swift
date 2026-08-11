import Foundation

/// Phase 1: Collect all history changes since last sync
struct HistoryCollectionPhase: SyncPhase {
    typealias Input = HistoryCollectionRequest
    typealias Output = HistoryCollectionResult

    let name = "History Collection"
    let progressRange: ClosedRange<Double> = 0.0...0.1

    private let messageFetcher: MessageFetcher
    private let historyProcessor: HistoryProcessor
    private let log = LogCategory.sync.logger

    /// Bounded page budget keeps one slice's history records and derived IDs
    /// predictable in memory. The next page token is persisted in Core Data.
    private let maxHistoryPages: Int
    private let maxResultsPerPage: Int

    init(
        messageFetcher: MessageFetcher,
        historyProcessor: HistoryProcessor,
        maxHistoryPages: Int = SyncConfig.maxHistoryPagesPerForegroundSlice,
        maxResultsPerPage: Int = SyncConfig.maxHistoryResultsPerRequest
    ) {
        self.messageFetcher = messageFetcher
        self.historyProcessor = historyProcessor
        self.maxHistoryPages = max(1, maxHistoryPages)
        self.maxResultsPerPage = max(1, min(maxResultsPerPage, 500))
    }

    func execute(
        input request: HistoryCollectionRequest,
        context: SyncPhaseContext
    ) async throws -> HistoryCollectionResult {
        context.reportProgress(0, status: "Fetching history...", phase: self)

        var pageToken = request.pageToken
        var latestHistoryId = request.startHistoryId
        var allNewMessageIds: Set<String> = []
        var allHistoryRecords: [HistoryRecord] = []
        var pageCount = 0

        repeat {
            try Task.checkCancellation()

            let (history, newHistoryId, nextPageToken) = try await messageFetcher.listHistory(
                startHistoryId: request.startHistoryId,
                pageToken: pageToken,
                maxResults: maxResultsPerPage
            )

            if let history = history, !history.isEmpty {
                log.debug("Received \(history.count) history records")
                let excludedSendEchoIDs = try await HistoryProcessor
                    .excludedRemoteSendEchoMessageIDs(
                        from: history,
                        in: context.coreDataContext
                    )
                let newIds = historyProcessor.extractNewMessageIds(
                    from: history,
                    includingExcludedMessageIDs: excludedSendEchoIDs
                )
                allNewMessageIds.formUnion(newIds)
                // Preserve the original history records for downstream lightweight processing.
                // Deletions and any future lightweight operations rely on the full record payload.
                allHistoryRecords.append(contentsOf: history)
            }

            if let newHistoryId = newHistoryId {
                latestHistoryId = newHistoryId
            }

            pageToken = nextPageToken
            pageCount += 1

            // Return the next token instead of discarding it. The orchestrator
            // stages it with this slice's effects in the final Core Data save.
            if pageCount >= maxHistoryPages && pageToken != nil {
                log.warning("History collection reached page limit (\(maxHistoryPages)); returning a resumable continuation")
                context.reportProgress(1.0, status: "History slice collected", phase: self)
                return HistoryCollectionResult(
                    newMessageIds: Array(allNewMessageIds),
                    records: allHistoryRecords,
                    latestHistoryId: latestHistoryId,
                    nextPageToken: pageToken
                )
            }
        } while pageToken != nil

        log.info("History collection: \(allNewMessageIds.count) unique messages, \(allHistoryRecords.count) records")

        context.reportProgress(1.0, status: "History collected", phase: self)

        return HistoryCollectionResult(
            newMessageIds: Array(allNewMessageIds),
            records: allHistoryRecords,
            latestHistoryId: latestHistoryId,
            nextPageToken: nil
        )
    }
}
