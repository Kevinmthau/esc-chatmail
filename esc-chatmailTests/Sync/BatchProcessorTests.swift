import XCTest
@testable import esc_chatmail

/// Characterization of `BatchProcessor.processMessages` batching mechanics:
/// per-chunk completion cadence, error propagation aborting later chunks, and
/// cancellation surfacing as `CancellationError` instead of silent success.
final class BatchProcessorTests: XCTestCase {

    private func makeFetcher(ids: [String], api: MockGmailAPIClient) -> MessageFetcher {
        for id in ids {
            api.getMessageResponses[id] = GmailMessageBuilder()
                .withId(id)
                .withThreadId("t-\(id)")
                .withLabels(["INBOX"])
                .build()
        }
        return MessageFetcher(apiClient: api, clock: FakeSyncClock())
    }

    func testBatchCompletionRunsOncePerChunkAfterProgress() async throws {
        let ids = ["a", "b", "c", "d", "e"]
        let api = MockGmailAPIClient()
        let fetcher = makeFetcher(ids: ids, api: api)

        let events = EventLog()
        let result = try await BatchProcessor.processMessages(
            messageIds: ids,
            batchSize: 2,
            messageFetcher: fetcher,
            progressHandler: { processed, total in
                await events.append("progress \(processed)/\(total)")
            },
            messageHandler: { messages in
                // successfulCount now reflects the persistence report, not
                // fetch success — report every message as persisted.
                var report = MessagePersistenceReport()
                for message in messages { report.record(message.id, .persisted) }
                return report
            },
            batchCompletion: {
                await events.append("completion")
            }
        )

        XCTAssertEqual(result.totalProcessed, 5)
        XCTAssertEqual(result.successfulCount, 5)
        XCTAssertTrue(result.failedIds.isEmpty)
        let recorded = await events.entries
        XCTAssertEqual(recorded, [
            "progress 2/5", "completion",
            "progress 4/5", "completion",
            "progress 5/5", "completion"
        ])
    }

    /// successfulCount reflects the persistence report, and persistence
    /// failures make the whole result a blocking failure even when every
    /// fetch succeeded.
    func testMixedPersistenceReportGatesResultTruthfully() async throws {
        let ids = ["a", "b", "c"]
        let api = MockGmailAPIClient()
        let fetcher = makeFetcher(ids: ids, api: api)

        let result = try await BatchProcessor.processMessages(
            messageIds: ids,
            batchSize: 3,
            messageFetcher: fetcher,
            progressHandler: { _, _ in },
            messageHandler: { messages in
                var report = MessagePersistenceReport()
                for (index, message) in messages.enumerated() {
                    report.record(message.id, index == 0 ? .failed : .persisted)
                }
                return report
            }
        )

        XCTAssertEqual(result.totalProcessed, 3)
        XCTAssertEqual(result.successfulCount, 2, "Only persisted messages count as successful")
        XCTAssertTrue(result.failedIds.isEmpty, "No fetch failures occurred")
        XCTAssertTrue(result.hasFailures, "A persistence failure must gate the cursor")
        XCTAssertEqual(result.blockingFailureIds.count, 1)
        XCTAssertEqual(result.persistence.failedIds.count, 1)
    }

    func testBatchCompletionErrorAbortsRemainingChunks() async {
        struct CompletionFailure: Error {}
        let ids = ["a", "b", "c", "d", "e", "f"]
        let api = MockGmailAPIClient()
        let fetcher = makeFetcher(ids: ids, api: api)

        let completions = Counter()
        do {
            _ = try await BatchProcessor.processMessages(
                messageIds: ids,
                batchSize: 2,
                messageFetcher: fetcher,
                progressHandler: { _, _ in },
                messageHandler: { _ in .empty },
                batchCompletion: {
                    let count = await completions.increment()
                    if count == 2 { throw CompletionFailure() }
                }
            )
            XCTFail("Expected the chunk-2 completion failure to propagate")
        } catch is CompletionFailure {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let completionCount = await completions.value
        XCTAssertEqual(completionCount, 2, "No completion may run after one throws")
        XCTAssertEqual(api.getMessageCallCount, 4, "Chunk 3 must not be fetched after the failure")
    }

    func testEmptyInputProducesEmptyResultWithoutFetchesOrCompletions() async throws {
        let api = MockGmailAPIClient()
        let fetcher = MessageFetcher(apiClient: api, clock: FakeSyncClock())

        let completions = Counter()
        let result = try await BatchProcessor.processMessages(
            messageIds: [],
            batchSize: 2,
            messageFetcher: fetcher,
            progressHandler: { _, _ in },
            messageHandler: { _ in .empty },
            batchCompletion: { _ = await completions.increment() }
        )

        XCTAssertEqual(result.totalProcessed, 0)
        XCTAssertEqual(result.successfulCount, 0)
        XCTAssertTrue(result.failedIds.isEmpty)
        XCTAssertEqual(api.getMessageCallCount, 0)
        let completionCount = await completions.value
        XCTAssertEqual(completionCount, 0)
    }

    /// Cancelling between chunks must surface as `CancellationError` — omitted
    /// chunks must never be reported as processed/successful.
    func testCancellationBetweenChunksThrowsInsteadOfReportingSuccess() async {
        let ids = ["a", "b", "c", "d"]
        let api = MockGmailAPIClient()
        let fetcher = makeFetcher(ids: ids, api: api)

        final class TaskBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _task: Task<BatchProcessingResult, Error>?

            var task: Task<BatchProcessingResult, Error>? {
                get { lock.withLock { _task } }
                set { lock.withLock { _task = newValue } }
            }
        }
        let box = TaskBox()

        box.task = Task {
            try await BatchProcessor.processMessages(
                messageIds: ids,
                batchSize: 2,
                messageFetcher: fetcher,
                progressHandler: { _, _ in },
                messageHandler: { _ in .empty },
                batchCompletion: {
                    // Cancel after the first chunk commits, waiting out the
                    // startup race where the box has not been assigned yet;
                    // chunk 2's checkCancellation must then abort the run.
                    while !Task.isCancelled {
                        box.task?.cancel()
                        await Task.yield()
                    }
                }
            )
        }

        do {
            _ = try await box.task?.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            XCTAssertEqual(api.getMessageCallCount, 2, "Chunk 2 must not run after cancellation")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - retryFailedMessages

    /// The completion retry gets every blocking failure of a whole run; it
    /// must fetch and persist them a chunk at a time, not in one batch held
    /// in memory, and still land every ID in exactly one bucket.
    ///
    /// Revert-check: call `fetchBatch(failedIds)` once in
    /// `retryFailedMessages` instead of looping over `chunked(into:)` and the
    /// largest persisted group is 118.
    func testRetryFailedMessages_fetchesInChunksAndPartitionsEveryIdOnce() async throws {
        let ids = (0..<120).map { "retry-\($0)" }
        let api = MockGmailAPIClient()
        let fetcher = makeFetcher(ids: Array(ids.dropLast(2)), api: api)
        api.getMessageErrors["retry-118"] = APIError.notFound("retry-118")
        api.getMessageErrors["retry-119"] = APIError.invalidData("retry-119")
        let groups = GroupLog()

        let outcome = try await BatchProcessor.retryFailedMessages(
            failedIds: ids,
            batchSize: 50,
            messageFetcher: fetcher
        ) { messages in
            await groups.append(messages.map(\.id))
            var report = MessagePersistenceReport()
            for message in messages { report.record(message.id, .persisted) }
            return report
        }

        let persistedGroups = await groups.groups
        XCTAssertLessThanOrEqual(persistedGroups.map(\.count).max() ?? 0, 50)
        XCTAssertEqual(outcome.persistence.persistedIds.count, 118)
        XCTAssertEqual(outcome.goneIds, ["retry-118"])
        XCTAssertEqual(outcome.fetchFailedIds, ["retry-119"])
        let partitioned = outcome.persistence.persistedIds + outcome.goneIds + outcome.fetchFailedIds
        XCTAssertEqual(Set(partitioned), Set(ids))
        XCTAssertEqual(partitioned.count, ids.count, "No ID may land in two buckets")
    }

    /// An account-scoped abort in a later chunk propagates and leaves the
    /// remaining chunks unrequested; earlier chunks were already persisted.
    /// (Within the aborting chunk, `fetchBatch` still persists the fetches
    /// that completed before it rethrows.)
    func testRetryFailedMessages_quotaAbortInLaterChunkPropagates() async throws {
        let ids = (0..<120).map { "retry-\($0)" }
        let api = MockGmailAPIClient()
        let fetcher = makeFetcher(ids: ids, api: api)
        api.getMessageErrors["retry-75"] = APIError.quotaExhausted("daily limit")
        let groups = GroupLog()

        do {
            _ = try await BatchProcessor.retryFailedMessages(
                failedIds: ids,
                batchSize: 50,
                messageFetcher: fetcher
            ) { messages in
                await groups.append(messages.map(\.id))
                var report = MessagePersistenceReport()
                for message in messages { report.record(message.id, .persisted) }
                return report
            }
            XCTFail("A quota abort must propagate")
        } catch APIError.quotaExhausted {
            // Expected.
        }

        let persisted = Set(await groups.groups.flatMap { $0 })
        XCTAssertTrue(Set(ids.prefix(50)).isSubset(of: persisted), "The chunk before the abort is persisted")
        XCTAssertFalse(persisted.contains("retry-75"), "The aborting ID gets no verdict")
        XCTAssertTrue(
            persisted.isDisjoint(with: ids.suffix(20)),
            "No chunk after the abort may be fetched or persisted"
        )
    }
}

private actor GroupLog {
    private(set) var groups: [[String]] = []
    func append(_ group: [String]) {
        groups.append(group)
    }
}

private actor EventLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) {
        entries.append(entry)
    }
}

private actor Counter {
    private(set) var value = 0
    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}
