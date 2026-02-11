import XCTest
@testable import esc_chatmail

final class MessageFetcherTests: XCTestCase {

    func testFetchBatch_includesExhaustedTransientFailuresInFailedIds() async {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageResponses["ok"] = GmailMessageBuilder().withId("ok").build()
        mockAPI.getMessageErrors["transient"] = APIError.timeout
        mockAPI.getMessageErrors["missing"] = APIError.notFound("missing")

        let fetcher = await MainActor.run { MessageFetcher(apiClient: mockAPI) }
        let successes = SuccessCollector()

        let failedIds = await fetcher.fetchBatch(["ok", "transient", "missing"]) { message in
            await successes.append(message.id)
        }

        let successfulIds = await successes.values()
        XCTAssertEqual(Set(successfulIds), Set(["ok"]))
        XCTAssertEqual(Set(failedIds), Set(["transient", "missing"]))
        XCTAssertEqual(mockAPI.getMessageCallCount, 6) // ok(1) + missing(1) + transient(4)
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
