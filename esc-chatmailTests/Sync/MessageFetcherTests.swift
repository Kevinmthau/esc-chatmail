import XCTest
@testable import esc_chatmail

final class MessageFetcherTests: XCTestCase {

    func testFetchBatch_includesExhaustedTransientFailuresInFailedIds() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageResponses["ok"] = GmailMessageBuilder().withId("ok").build()
        mockAPI.getMessageErrors["transient"] = APIError.timeout
        mockAPI.getMessageErrors["missing"] = APIError.notFound("missing")

        let clock = FakeSyncClock()
        let fetcher = MessageFetcher(apiClient: mockAPI, clock: clock)
        let successes = SuccessCollector()

        let failedIds = await fetcher.fetchBatch(["ok", "transient", "missing"]) { messages in
            for message in messages {
                await successes.append(message.id)
            }
        }

        let successfulIds = await successes.values()
        XCTAssertEqual(Set(successfulIds), Set(["ok"]))
        XCTAssertEqual(Set(failedIds), Set(["transient", "missing"]))
        XCTAssertEqual(mockAPI.getMessageCallCount, 6) // ok(1) + missing(1) + transient(4)
        XCTAssertEqual(clock.sleeps.count, 3, "One backoff sleep per retry attempt")
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
