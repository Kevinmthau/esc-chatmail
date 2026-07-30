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
        } pageCompletion: {
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
