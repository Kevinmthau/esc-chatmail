import XCTest
@testable import esc_chatmail

/// The page progress an interrupted initial sync or history recovery
/// resumes from (scalability review step 8).
final class PagedSyncProgressTests: XCTestCase {
    private static let now: TimeInterval = 1_800_000_000

    /// The failures of the pages saved by earlier attempts are carried into
    /// each later page's progress; a resumed run whose own pages are clean
    /// must still see them, or it advances past messages never stored.
    ///
    /// Revert-check: build `fetchFailedIds` in `PagedSyncProgress.afterPage`
    /// from the page alone and "early-fetch" is dropped.
    func testAfterPage_carriesEarlierAttemptsFailuresWithoutDuplicates() {
        let prior = makeProgress(
            token: "page-3",
            fetchFailed: ["early-fetch", "both"],
            persistenceFailed: ["early-save"],
            resolved: ["d-1"]
        )
        let page = MessageListPageProgress(
            nextPageToken: "page-4",
            fetchFailedIds: ["both", "late-fetch"],
            persistenceFailedIds: [],
            resolvedTrackedIds: ["d-2"]
        )

        let next = PagedSyncProgress.afterPage(
            page,
            prior: prior,
            watermarkHistoryId: prior.watermarkHistoryId,
            listingStartedAt: prior.listingStartedAt
        )

        XCTAssertEqual(next.nextPageToken, "page-4")
        XCTAssertEqual(next.fetchFailedIds, ["early-fetch", "both", "late-fetch"])
        XCTAssertEqual(next.persistenceFailedIds, ["early-save"])
        XCTAssertEqual(next.resolvedTrackedIds, ["d-1", "d-2"])
        XCTAssertEqual(next.watermarkHistoryId, "history-500")
    }

    /// The listing result a resumed run completes with holds the earlier
    /// attempts' failures beside its own, and its resolutions.
    ///
    /// Revert-check: return `result` unchanged from `merging(into:)` and the
    /// blocking failures lose "early-fetch" and "early-save".
    func testMerging_addsEarlierFailuresAndResolutions() {
        let prior = makeProgress(
            token: nil,
            fetchFailed: ["early-fetch"],
            persistenceFailed: ["early-save"],
            resolved: ["d-1"]
        )
        var persistence = MessagePersistenceReport()
        persistence.record("late-save", .failed)
        let result = BatchProcessingResult(
            totalProcessed: 3,
            successfulCount: 2,
            failedIds: ["late-fetch"],
            persistence: persistence,
            resolvedTrackedIds: ["d-2"]
        )

        let merged = prior.merging(into: result)

        XCTAssertEqual(Set(merged.blockingFailureIds), ["early-fetch", "late-fetch", "early-save", "late-save"])
        XCTAssertEqual(merged.resolvedTrackedIds, ["d-1", "d-2"])
        XCTAssertEqual(merged.totalProcessed, 3, "Counts stay this attempt's")
        XCTAssertTrue(prior.isListingComplete)
        XCTAssertEqual(Set(prior.completedListingResult.blockingFailureIds), ["early-fetch", "early-save"])
    }

    /// A listing too old to resume (its watermark may have left Gmail's
    /// history) lists its frozen window again from the first page.
    ///
    /// Revert-check: return true from `PagedSyncProgress.isResumable(at:)`
    /// and the four-day-old listing is resumed.
    func testListing_resumesOnlyProgressYoungerThanTheResumeMaxAge() {
        let fresh = makeProgress(token: "page-2", startedAgo: 3600)
        let stale = makeProgress(token: "page-2", startedAgo: SyncConfig.pagedSyncResumeMaxAge + 3600)
        let future = makeProgress(token: "page-2", startedAgo: -3600)

        func listing(_ progress: PagedSyncProgress) -> PagedSyncListing {
            PagedSyncListing(
                resuming: SyncWindowCheckpoint(accountEmail: "me@example.com", windowStart: 42, progress: progress),
                now: Self.now
            )
        }

        XCTAssertEqual(listing(fresh).progress, fresh)
        XCTAssertNil(listing(stale).progress)
        XCTAssertNil(listing(future).progress, "A clock that moved back proves nothing about the watermark's age")
        XCTAssertEqual(listing(stale).windowStart, 42, "The window stays frozen")
    }

    private func makeProgress(
        token: String?,
        fetchFailed: [String] = [],
        persistenceFailed: [String] = [],
        resolved: [String] = [],
        startedAgo: TimeInterval = 60
    ) -> PagedSyncProgress {
        PagedSyncProgress(
            watermarkHistoryId: "history-500",
            listingStartedAt: Self.now - startedAgo,
            nextPageToken: token,
            fetchFailedIds: fetchFailed,
            persistenceFailedIds: persistenceFailed,
            resolvedTrackedIds: resolved
        )
    }
}
