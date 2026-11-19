import Foundation

/// How far an initial sync or a history recovery has listed, so an attempt
/// that dies part-way (a kill, a cancellation, a background task's expiry, an
/// account-scoped abort) is resumed at its next page by the next attempt,
/// not at page 1 (scalability review step 8: `initial-sync-no-durable-checkpoint`,
/// `history-recovery-no-checkpoint`).
///
/// It rides in the run's `SyncWindowCheckpoint` row and is staged into the
/// sync context by each page's completion, so it commits in that page's save
/// with the page's messages, and never apart from them.
///
/// Three things here are load-bearing.
/// - The failures of earlier pages are carried, never dropped: they were held
///   only in memory, and a resumed run whose own pages were clean would
///   otherwise advance the cursor past messages that were never stored.
///   They are retried at completion with this attempt's own failures.
/// - The cursor a resumed run advances to is the watermark taken before the
///   listing's first page, in the first attempt. Mail that arrived since, and
///   label changes to the pages listed earlier, are what the history from
///   that watermark covers; a later attempt's own watermark would skip them.
///   A listing older than `SyncConfig.pagedSyncResumeMaxAge` is not resumed,
///   because its watermark may have left Gmail's history.
/// - Once listing is complete (`nextPageToken == nil`) a resumed run lists
///   nothing and goes straight to the completion retry.
struct PagedSyncProgress: Equatable, Sendable, Codable {
    /// The profile's `historyId` read before the listing's first page.
    let watermarkHistoryId: String
    /// When the listing's first page was asked for, in Unix seconds.
    let listingStartedAt: TimeInterval
    /// The page to list next; nil once the listing has ended.
    let nextPageToken: String?
    /// IDs whose fetch failed on a page already saved.
    let fetchFailedIds: [String]
    /// IDs whose persistence failed on a page already saved.
    let persistenceFailedIds: [String]
    /// Deferred-ledger IDs the listing has already resolved, so the
    /// completion retry does not fetch them again.
    let resolvedTrackedIds: [String]

    var isListingComplete: Bool {
        nextPageToken == nil
    }

    /// Whether an attempt started at `now` may resume this listing.
    func isResumable(at now: TimeInterval) -> Bool {
        guard listingStartedAt.isFinite, !watermarkHistoryId.isEmpty else { return false }
        let age = now - listingStartedAt
        return age >= 0 && age <= SyncConfig.pagedSyncResumeMaxAge
    }

    /// The progress after one more saved page: this attempt's cumulative
    /// failures and resolutions added to the earlier attempts' (`prior`).
    static func afterPage(
        _ page: MessageListPageProgress,
        prior: PagedSyncProgress?,
        watermarkHistoryId: String,
        listingStartedAt: TimeInterval
    ) -> PagedSyncProgress {
        PagedSyncProgress(
            watermarkHistoryId: watermarkHistoryId,
            listingStartedAt: listingStartedAt,
            nextPageToken: page.nextPageToken,
            fetchFailedIds: orderedUnion(prior?.fetchFailedIds ?? [], page.fetchFailedIds),
            persistenceFailedIds: orderedUnion(
                prior?.persistenceFailedIds ?? [],
                page.persistenceFailedIds
            ),
            resolvedTrackedIds: orderedUnion(
                prior?.resolvedTrackedIds ?? [],
                page.resolvedTrackedIds.sorted()
            )
        )
    }

    /// This attempt's listing result with the earlier attempts' failures and
    /// resolutions added. Counts stay this attempt's.
    func merging(into result: BatchProcessingResult) -> BatchProcessingResult {
        var persistence = result.persistence
        let failedThisAttempt = Set(persistence.failedIds)
        for id in persistenceFailedIds where !failedThisAttempt.contains(id) {
            persistence.record(id, .failed)
        }
        return BatchProcessingResult(
            totalProcessed: result.totalProcessed,
            successfulCount: result.successfulCount,
            failedIds: Self.orderedUnion(fetchFailedIds, result.failedIds),
            goneIds: result.goneIds,
            persistence: persistence,
            resolvedTrackedIds: result.resolvedTrackedIds.union(resolvedTrackedIds)
        )
    }

    /// The earlier attempts' failures and resolutions alone, for a resumed
    /// run whose listing had already ended.
    var completedListingResult: BatchProcessingResult {
        merging(into: BatchProcessingResult(totalProcessed: 0, successfulCount: 0, failedIds: []))
    }

    private static func orderedUnion(_ first: [String], _ second: [String]) -> [String] {
        var seen = Set<String>()
        return (first + second).filter { seen.insert($0).inserted }
    }
}
