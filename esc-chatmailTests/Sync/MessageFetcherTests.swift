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

    // MARK: - fetchAbandonedMessages

    func testFetchAbandonedMessages_classifiesOutcomes() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageResponses["ok"] = GmailMessageBuilder().withId("ok").build()
        mockAPI.getMessageErrors["gone"] = APIError.notFound("gone")
        mockAPI.getMessageErrors["transient"] = APIError.timeout

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let result = await fetcher.fetchAbandonedMessages(["ok", "gone", "transient"])

        XCTAssertEqual(result.fetched.map(\.id), ["ok"])
        XCTAssertEqual(result.goneIds, ["gone"])
        XCTAssertEqual(result.failedIds, ["transient"])
        XCTAssertEqual(mockAPI.getMessageCallCount, 3, "Abandoned retries make a single attempt per ID, no retry loop")
    }

    func testFetchAbandonedMessages_non404PermanentErrorsAreFailedNotGone() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageErrors["auth"] = APIError.authenticationError
        mockAPI.getMessageErrors["forbidden"] = APIError.invalidData("Gmail API 403: rate limited")

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let result = await fetcher.fetchAbandonedMessages(["auth", "forbidden"])

        XCTAssertTrue(result.goneIds.isEmpty, "Only a 404 proves the message is gone; auth/403 errors must not delete tracking records")
        XCTAssertEqual(Set(result.failedIds), Set(["auth", "forbidden"]))
    }

    func testFetchAbandonedMessages_quotaExhaustionRecordsNoOutcomes() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageErrors["stuck"] = APIError.quotaExhausted("Daily Limit Exceeded")

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let result = await fetcher.fetchAbandonedMessages(["stuck"])

        XCTAssertTrue(result.fetched.isEmpty)
        XCTAssertTrue(result.goneIds.isEmpty)
        XCTAssertTrue(
            result.failedIds.isEmpty,
            "Quota exhaustion is not an attempt outcome - recording it would burn the abandoned-drain retry budget"
        )
    }

    func testFetchAbandonedMessages_emptyInput_returnsEmpty() async {
        let mockAPI = MockGmailAPIClient()

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let result = await fetcher.fetchAbandonedMessages([])

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
