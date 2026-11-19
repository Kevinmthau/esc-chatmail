import XCTest
@testable import esc_chatmail

final class MessageListPaginatorTests: XCTestCase {
    func testFetchAndProcess_streamsPagesWithoutCollectingAllIdsFirst() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageListWithPagination(
            [["a", "b"], ["c"]],
            pageTokens: ["page-2", nil]
        )
        mockAPI.getMessageResponses["a"] = GmailMessageBuilder().withId("a").withInternalDateMillis(1).build()
        mockAPI.getMessageResponses["b"] = GmailMessageBuilder().withId("b").withInternalDateMillis(2).build()
        mockAPI.getMessageResponses["c"] = GmailMessageBuilder().withId("c").withInternalDateMillis(3).build()

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let persisted = OrderedIDCollector()
        let checkpoints = CheckpointCollector()
        let listCountsAtPersist = IntCollector()
        let pageCompletions = Counter()

        let result = try await MessageListPaginator.fetchAndProcess(
            query: "after:1",
            batchSize: 2,
            messageFetcher: fetcher
        ) { checkpoint in
            await checkpoints.append(checkpoint)
        } messageHandler: { messages in
            await persisted.append(contentsOf: messages.map(\.id))
            await listCountsAtPersist.append(mockAPI.listMessagesCallCount)
            var report = MessagePersistenceReport()
            for message in messages { report.record(message.id, .persisted) }
            return report
        } pageCompletion: { _ in
            await pageCompletions.increment()
        }

        XCTAssertEqual(result.totalProcessed, 3)
        XCTAssertEqual(result.successfulCount, 3)
        XCTAssertEqual(result.failedIds, [])
        let persistedIDs = await persisted.values()
        let pageCompletionCount = await pageCompletions.value
        let checkpointValues = await checkpoints.values()
        let listCounts = await listCountsAtPersist.values()
        XCTAssertEqual(persistedIDs, ["a", "b", "c"])
        XCTAssertEqual(listCounts, [1, 2])
        XCTAssertEqual(pageCompletionCount, 2)
        XCTAssertEqual(mockAPI.listMessagesCallCount, 2)
        XCTAssertEqual(checkpointValues.last?.processedCount, 3)
        XCTAssertEqual(checkpointValues.last?.isComplete, true)
    }

    /// The run-wide result keeps IDs only for the failure buckets: a
    /// since-install re-list would otherwise hold every listed ID until the
    /// run ends, while callers read only counts and failure IDs.
    ///
    /// Revert-check: merge `pageResult.persistence` in `fetchAndProcess`
    /// instead of `.retainingOnlyFailures` and `persistedIds` is non-empty.
    func testFetchAndProcess_runWideResultKeepsOnlyFailureIds() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageListWithPagination(
            [["ok-1", "bad"], ["ok-2", "gone"]],
            pageTokens: ["page-2", nil]
        )
        for id in ["ok-1", "bad", "ok-2"] {
            mockAPI.getMessageResponses[id] = GmailMessageBuilder().withId(id).build()
        }
        mockAPI.getMessageErrors["gone"] = APIError.notFound("gone")

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI, clock: FakeSyncClock()) }
        let result = try await MessageListPaginator.fetchAndProcess(
            query: "after:1",
            batchSize: 2,
            messageFetcher: fetcher
        ) { _ in
        } messageHandler: { messages in
            var report = MessagePersistenceReport()
            for message in messages {
                report.record(message.id, message.id == "bad" ? .failed : .persisted)
            }
            return report
        }

        XCTAssertEqual(result.totalProcessed, 4)
        XCTAssertEqual(result.successfulCount, 2)
        XCTAssertEqual(result.persistence.failedIds, ["bad"])
        XCTAssertEqual(result.blockingFailureIds, ["bad"])
        XCTAssertTrue(result.persistence.persistedIds.isEmpty)
        XCTAssertTrue(result.goneIds.isEmpty)
    }

    /// `resolvedTrackedIds` reports every tracked ID the listing settled —
    /// persisted, excluded, unprocessable or gone — across pages, and nothing
    /// else: not a tracked ID that failed, nor any untracked ID.
    ///
    /// Revert-check: drop any one bucket from the `resolvedTrackedIds`
    /// aggregation in `fetchAndProcess` and its tracked ID goes missing;
    /// drop the `trackedIds.contains` filter and the untracked IDs appear.
    func testFetchAndProcess_reportsResolvedTrackedIdsFromEveryResolvingBucket() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageListWithPagination(
            [["t-kept", "t-excluded", "untracked"], ["t-junk", "t-gone", "t-failed"]],
            pageTokens: ["page-2", nil]
        )
        for id in ["t-kept", "t-excluded", "untracked", "t-junk", "t-failed"] {
            mockAPI.getMessageResponses[id] = GmailMessageBuilder().withId(id).build()
        }
        mockAPI.getMessageErrors["t-gone"] = APIError.notFound("gone")
        let dispositions: [String: MessagePersistDisposition] = [
            "t-excluded": .excluded,
            "t-junk": .unprocessable,
            "t-failed": .failed
        ]

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI, clock: FakeSyncClock()) }
        let result = try await MessageListPaginator.fetchAndProcess(
            query: "after:1",
            batchSize: 3,
            messageFetcher: fetcher,
            trackedIds: ["t-kept", "t-excluded", "t-junk", "t-gone", "t-failed", "t-unlisted"]
        ) { _ in
        } messageHandler: { messages in
            var report = MessagePersistenceReport()
            for message in messages {
                report.record(message.id, dispositions[message.id] ?? .persisted)
            }
            return report
        }

        XCTAssertEqual(result.resolvedTrackedIds, ["t-kept", "t-excluded", "t-junk", "t-gone"])
        XCTAssertEqual(result.blockingFailureIds, ["t-failed"], "Positive control: the failure was attempted")
    }

    func testMessageIDPageStreamReportsEachPageTokenInOrder() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageListWithPagination(
            [["first"], ["second"], []],
            pageTokens: ["page-2", "page-3", nil]
        )

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let stream = MessageIDPageStream(query: "newer_than:1d", pageSize: 10, messageFetcher: fetcher)
        var pages: [MessageIDPage] = []

        try await stream.forEachPage { page in
            pages.append(page)
        }

        XCTAssertEqual(pages.map(\.pageIndex), [1, 2, 3])
        XCTAssertEqual(pages.map(\.messageIds), [["first"], ["second"], []])
        XCTAssertEqual(pages.map(\.nextPageToken), ["page-2", "page-3", nil])
    }

    /// A resumed listing starts at the page its interrupted attempt stopped
    /// before, never at the first page.
    ///
    /// Revert-check: start `MessageIDPageStream.forEachPage` at a nil page
    /// token instead of `startPageToken` and "first" is listed again.
    func testMessageIDPageStream_startsAtTheStartPageToken() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageListWithPagination(
            [["first"], ["second"], ["third"]],
            pageTokens: ["page-2", "page-3", nil]
        )

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let stream = MessageIDPageStream(
            query: "after:1",
            messageFetcher: fetcher,
            startPageToken: "page-2"
        )
        var pages: [MessageIDPage] = []
        try await stream.forEachPage { pages.append($0) }

        XCTAssertEqual(pages.map(\.messageIds), [["second"], ["third"]])
        XCTAssertEqual(mockAPI.listMessagesCallCount, 2)
    }

    /// Gmail answers a stored page token it no longer honors with a 400. The
    /// stored token is given up once and the listing starts again from its
    /// first page; it does not fail the run.
    ///
    /// Revert-check: rethrow every `APIError` from the list call in
    /// `MessageIDPageStream.forEachPage` and the stream throws `invalidData`.
    func testMessageIDPageStream_rejectedStartPageToken_listsFromTheFirstPage() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageListWithPagination(
            [["first"], ["second"]],
            pageTokens: ["page-2", nil]
        )
        mockAPI.listMessagesErrorsByPageToken["stale"] = APIError.invalidData("Gmail API 400: Invalid pageToken")

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let stream = MessageIDPageStream(query: "after:1", messageFetcher: fetcher, startPageToken: "stale")
        var pages: [MessageIDPage] = []
        try await stream.forEachPage { pages.append($0) }

        XCTAssertEqual(pages.map(\.messageIds), [["first"], ["second"]])
        XCTAssertEqual(pages.map(\.pageIndex), [1, 2])
    }

    /// Only the stored token is given up: a 400 on a token Gmail itself just
    /// handed out, or any other error on the stored one, still fails.
    func testMessageIDPageStream_otherListFailures_propagate() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageListWithPagination(
            [["first"], ["second"]],
            pageTokens: ["page-2", nil]
        )
        mockAPI.listMessagesErrorsByPageToken["page-2"] = APIError.invalidData("Gmail API 400")
        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }

        let fresh = MessageIDPageStream(query: "after:1", messageFetcher: fetcher)
        do {
            try await fresh.forEachPage { _ in }
            XCTFail("A 400 on a token Gmail just issued must not restart the listing")
        } catch APIError.invalidData(_) {
            // Expected.
        }

        let transientOrAccountScoped: [APIError] = [
            .serverError(503),
            .timeout,
            .rateLimited(retryAfter: nil),
            .authenticationError,
            .credentialsRevoked,
            .quotaExhausted("daily")
        ]
        for error in transientOrAccountScoped {
            mockAPI.listMessagesErrorsByPageToken["stored"] = error
            let resumed = MessageIDPageStream(query: "after:1", messageFetcher: fetcher, startPageToken: "stored")
            do {
                try await resumed.forEachPage { _ in }
                XCTFail("\(error) must not give up the stored token")
            } catch is APIError {
                // Expected.
            }
        }
    }

    /// A stored token refused some other deterministic way than a 400 (a
    /// 404, say: nobody has measured what Gmail answers) is given up the
    /// same way. Propagated, it failed every attempt at its first list call
    /// until the progress was three days old.
    ///
    /// Revert-check: give up the stored token only on `.invalidData` in
    /// `MessageIDPageStream.forEachPage` (or answer false for `.notFound` in
    /// `refusesStoredPageToken`) and the stream throws `notFound`.
    func testMessageIDPageStream_storedTokenNotFound_listsFromTheFirstPage() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageListWithPagination(
            [["first"], ["second"]],
            pageTokens: ["page-2", nil]
        )
        mockAPI.listMessagesErrorsByPageToken["stale"] = APIError.notFound("Requested entity was not found.")

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let stream = MessageIDPageStream(query: "after:1", messageFetcher: fetcher, startPageToken: "stale")
        var pages: [MessageIDPage] = []
        try await stream.forEachPage { pages.append($0) }

        XCTAssertEqual(pages.map(\.messageIds), [["first"], ["second"]])
    }

    /// A resumed first page that comes back empty with no next token is not
    /// trusted as the end of the listing: a stored token Gmail had expired
    /// could answer that way and end, clean, a listing that never reached
    /// its later pages. The listing starts again from its first page.
    ///
    /// Revert-check: drop the empty-and-last check from
    /// `MessageIDPageStream.forEachPage` and the stream ends after one empty
    /// page.
    func testMessageIDPageStream_resumedFirstPageEmptyAndLast_listsFromTheFirstPage() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageListWithPagination(
            [["first"], ["second"], []],
            pageTokens: ["page-2", "page-3", nil]
        )

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let stream = MessageIDPageStream(query: "after:1", messageFetcher: fetcher, startPageToken: "page-3")
        var pages: [MessageIDPage] = []
        try await stream.forEachPage { pages.append($0) }

        XCTAssertEqual(pages.map(\.messageIds), [["first"], ["second"], []])
        XCTAssertEqual(pages.map(\.pageIndex), [1, 2, 3])
    }

    /// Only the stored token's first answer is doubted: an empty last page
    /// reached from a resumed page that listed something ends the listing.
    func testMessageIDPageStream_resumedListingEndingOnAnEmptyPage_ends() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageListWithPagination(
            [["first"], ["second"], []],
            pageTokens: ["page-2", "page-3", nil]
        )

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let stream = MessageIDPageStream(query: "after:1", messageFetcher: fetcher, startPageToken: "page-2")
        var pages: [MessageIDPage] = []
        try await stream.forEachPage { pages.append($0) }

        XCTAssertEqual(pages.map(\.messageIds), [["second"], []])
    }

    /// Each page's completion carries the page to list next and the call's
    /// cumulative failures, which the orchestrators stage into that page's
    /// save so a resumed run keeps the failures of the pages before it.
    ///
    /// Revert-check: pass an empty `fetchFailedIds` in the paginator's
    /// `pageProgress()` and the second page's progress loses "bad-fetch".
    func testFetchAndProcess_pageCompletionReportsCumulativeFailures() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.setMessageListWithPagination(
            [["bad-fetch", "ok-1"], ["bad-save", "t-ok"]],
            pageTokens: ["page-2", nil]
        )
        for id in ["ok-1", "bad-save", "t-ok"] {
            mockAPI.getMessageResponses[id] = GmailMessageBuilder().withId(id).build()
        }
        mockAPI.getMessageErrors["bad-fetch"] = APIError.timeout

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI, clock: FakeSyncClock()) }
        let progress = PageProgressCollector()
        _ = try await MessageListPaginator.fetchAndProcess(
            query: "after:1",
            batchSize: 2,
            messageFetcher: fetcher,
            trackedIds: ["t-ok"]
        ) { _ in
        } messageHandler: { messages in
            var report = MessagePersistenceReport()
            for message in messages {
                report.record(message.id, message.id == "bad-save" ? .failed : .persisted)
            }
            return report
        } pageCompletion: { page in
            await progress.append(page)
        }

        let pages = await progress.values()
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.first?.nextPageToken, "page-2")
        XCTAssertEqual(pages.first?.fetchFailedIds, ["bad-fetch"])
        XCTAssertEqual(pages.last?.nextPageToken, nil)
        XCTAssertEqual(pages.last?.fetchFailedIds, ["bad-fetch"])
        XCTAssertEqual(pages.last?.persistenceFailedIds, ["bad-save"])
        XCTAssertEqual(pages.last?.resolvedTrackedIds, ["t-ok"])
    }
}

private actor OrderedIDCollector {
    private var ids: [String] = []

    func append(contentsOf newIDs: [String]) {
        ids.append(contentsOf: newIDs)
    }

    func values() -> [String] {
        ids
    }
}

private actor CheckpointCollector {
    private var checkpoints: [PagedSyncCheckpoint] = []

    func append(_ checkpoint: PagedSyncCheckpoint) {
        checkpoints.append(checkpoint)
    }

    func values() -> [PagedSyncCheckpoint] {
        checkpoints
    }
}

private actor IntCollector {
    private var ints: [Int] = []

    func append(_ value: Int) {
        ints.append(value)
    }

    func values() -> [Int] {
        ints
    }
}

private actor Counter {
    private var count = 0

    var value: Int {
        count
    }

    func increment() {
        count += 1
    }
}

private actor PageProgressCollector {
    private var pages: [MessageListPageProgress] = []

    func append(_ page: MessageListPageProgress) {
        pages.append(page)
    }

    func values() -> [MessageListPageProgress] {
        pages
    }
}
