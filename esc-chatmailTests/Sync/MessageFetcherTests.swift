import XCTest
@testable import esc_chatmail

final class MessageFetcherTests: XCTestCase {

    func testFetchBatch_separatesExhaustedFailuresFromGoneMessages() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageResponses["ok"] = GmailMessageBuilder().withId("ok").build()
        mockAPI.getMessageErrors["transient"] = APIError.timeout
        mockAPI.getMessageErrors["missing"] = APIError.notFound("missing")

        let clock = FakeSyncClock()
        let fetcher = MessageFetcher(apiClient: mockAPI, clock: clock)
        let successes = SuccessCollector()

        let outcome = try await fetcher.fetchBatch(["ok", "transient", "missing"]) { messages in
            for message in messages {
                await successes.append(message.id)
            }
            return .empty
        }

        let successfulIds = await successes.values()
        XCTAssertEqual(Set(successfulIds), Set(["ok"]))
        XCTAssertEqual(
            outcome.fetchFailedIds, ["transient"],
            "Only exhausted/permanent fetch errors block the cursor"
        )
        XCTAssertEqual(
            outcome.goneIds, ["missing"],
            "A 404 is a terminal outcome — it must not freeze the cursor as a failure"
        )
        XCTAssertEqual(mockAPI.getMessageCallCount, 6) // ok(1) + missing(1) + transient(4)
        XCTAssertEqual(clock.sleeps.count, 3, "One backoff sleep per retry attempt")
    }

    // MARK: - History listing

    func testListHistoryPassesMaxResultsThroughToTheClient() async throws {
        let mockAPI = MockGmailAPIClient()
        let fetcher = MessageFetcher(apiClient: mockAPI, clock: FakeSyncClock())

        _ = try await fetcher.listHistory(startHistoryId: "100", maxResults: 25)
        XCTAssertEqual(mockAPI.listHistoryLastMaxResults, 25)

        _ = try await fetcher.listHistory(startHistoryId: "100")
        XCTAssertNil(
            mockAPI.listHistoryLastMaxResults,
            "Omitting the cap must leave the server default in effect"
        )
    }

    // MARK: - Quota exhaustion

    func testFetchBatch_quotaExhaustionThrowsInsteadOfRecordingPerMessageFailures() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageErrors["quota"] = APIError.quotaExhausted("Daily Limit Exceeded")

        let clock = FakeSyncClock()
        let fetcher = MessageFetcher(apiClient: mockAPI, clock: clock)

        do {
            _ = try await fetcher.fetchBatch(["quota"]) { _ in .empty }
            XCTFail("Quota exhaustion must abort the run, not return the ID as a per-message failure")
        } catch let APIError.quotaExhausted(message) {
            XCTAssertTrue(message.contains("Daily Limit Exceeded"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(mockAPI.getMessageCallCount, 1, "Quota exhaustion cannot recover within the run - no retry passes")
        XCTAssertTrue(clock.sleeps.isEmpty, "No retry backoff for an aborted run")
    }

    func testFetchBatch_authenticationErrorAbortsInsteadOfRecordingPerMessageFailure() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageErrors["auth"] = APIError.authenticationError

        let clock = FakeSyncClock()
        let fetcher = MessageFetcher(apiClient: mockAPI, clock: clock)

        do {
            _ = try await fetcher.fetchBatch(["auth"]) { _ in
                XCTFail("An authentication failure cannot produce messages to persist")
                return .empty
            }
            XCTFail("Authentication failure must abort the sync run")
        } catch let error as APIError {
            guard case .authenticationError = error else {
                return XCTFail("Expected authenticationError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(mockAPI.getMessageCallCount, 1)
        XCTAssertTrue(clock.sleeps.isEmpty, "Account auth recovery happens outside the per-message retry loop")
    }

    func testFetchBatch_revokedCredentialsAbortInsteadOfRecordingPerMessageFailure() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageErrors["revoked"] = APIError.credentialsRevoked

        let clock = FakeSyncClock()
        let fetcher = MessageFetcher(apiClient: mockAPI, clock: clock)

        do {
            _ = try await fetcher.fetchBatch(["revoked"]) { _ in
                XCTFail("Revoked credentials cannot produce messages to persist")
                return .empty
            }
            XCTFail("Revoked credentials must abort the sync run")
        } catch let error as APIError {
            guard case .credentialsRevoked = error else {
                return XCTFail("Expected credentialsRevoked, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(mockAPI.getMessageCallCount, 1)
        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    // MARK: - Cancellation completeness

    func testFetchBatch_cancellationDuringMessageFanoutThrows() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageResponses["slow"] = GmailMessageBuilder().withId("slow").build()
        mockAPI.artificialDelay = 10
        let fetcher = MessageFetcher(apiClient: mockAPI, clock: FakeSyncClock())

        let task = Task {
            try await fetcher.fetchBatch(["slow"]) { _ in .empty }
        }
        for _ in 0..<1_000 where mockAPI.getMessageCallCountSnapshot() == 0 {
            await Task.yield()
        }
        XCTAssertEqual(mockAPI.getMessageCallCountSnapshot(), 1)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("An incomplete fan-out must not return a normal batch outcome")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testFetchBatch_cancellationDuringRetryBackoffThrows() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageErrors["retry"] = APIError.timeout
        let clock = LongSuspendingSyncClock()
        let fetcher = MessageFetcher(apiClient: mockAPI, clock: clock)

        let task = Task {
            try await fetcher.fetchBatch(["retry"]) { _ in .empty }
        }
        for _ in 0..<1_000 where !clock.hasStartedSleeping {
            await Task.yield()
        }
        XCTAssertTrue(clock.hasStartedSleeping)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelling retry backoff must abort the batch")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    // MARK: - fetchAbandonedMessages

    func testFetchAbandonedMessages_classifiesOutcomes() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageResponses["ok"] = GmailMessageBuilder().withId("ok").build()
        mockAPI.getMessageErrors["gone"] = APIError.notFound("gone")
        mockAPI.getMessageErrors["transient"] = APIError.timeout

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let result = try await fetcher.fetchAbandonedMessages(["ok", "gone", "transient"])

        XCTAssertEqual(result.fetched.map(\.id), ["ok"])
        XCTAssertEqual(result.goneIds, ["gone"])
        XCTAssertEqual(result.failedIds, ["transient"])
        XCTAssertEqual(mockAPI.getMessageCallCount, 3, "Abandoned retries make a single attempt per ID, no retry loop")
    }

    func testFetchAbandonedMessages_messageScopedPermanentErrorIsFailedNotGone() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageErrors["forbidden"] = APIError.invalidData("Gmail API 403: rate limited")

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let result = try await fetcher.fetchAbandonedMessages(["forbidden"])

        XCTAssertTrue(result.goneIds.isEmpty, "Only a 404 proves the message is gone")
        XCTAssertEqual(result.failedIds, ["forbidden"])
    }

    func testFetchAbandonedMessages_authenticationErrorAbortsTheDrain() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageErrors["auth"] = APIError.authenticationError

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        do {
            _ = try await fetcher.fetchAbandonedMessages(["auth"])
            XCTFail("Authentication failure must abort without spending the abandoned retry budget")
        } catch let error as APIError {
            guard case .authenticationError = error else {
                return XCTFail("Expected authenticationError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchAbandonedMessages_revokedCredentialsAbortTheDrain() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageErrors["revoked"] = APIError.credentialsRevoked

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        do {
            _ = try await fetcher.fetchAbandonedMessages(["revoked"])
            XCTFail("Revoked credentials must abort without aging out the abandoned pointer")
        } catch let error as APIError {
            guard case .credentialsRevoked = error else {
                return XCTFail("Expected credentialsRevoked, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchAbandonedMessages_quotaExhaustionAbortsTheDrain() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageErrors["stuck"] = APIError.quotaExhausted("Daily Limit Exceeded")

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        do {
            _ = try await fetcher.fetchAbandonedMessages(["stuck"])
            XCTFail("Quota exhaustion must abort without spending the abandoned retry budget")
        } catch let APIError.quotaExhausted(message) {
            XCTAssertTrue(message.contains("Daily Limit Exceeded"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchAbandonedMessages_emptyInput_returnsEmpty() async throws {
        let mockAPI = MockGmailAPIClient()

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let result = try await fetcher.fetchAbandonedMessages([])

        XCTAssertTrue(result.fetched.isEmpty)
        XCTAssertTrue(result.goneIds.isEmpty)
        XCTAssertTrue(result.failedIds.isEmpty)
        XCTAssertEqual(mockAPI.getMessageCallCount, 0)
    }

}

private actor SuccessCollector {
    private var ids: [String] = []

    func append(_ id: String) {
        ids.append(id)
    }

    func values() -> [String] {
        ids
    }
}

private final class LongSuspendingSyncClock: SyncClock, @unchecked Sendable {
    private let lock = NSLock()
    private var startedSleeping = false

    var hasStartedSleeping: Bool {
        lock.withLock { startedSleeping }
    }

    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }

    func sleep(nanoseconds: UInt64) async throws {
        lock.withLock { startedSleeping = true }
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}
