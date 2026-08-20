import XCTest
@testable import esc_chatmail

/// Direct coverage for `ConversationSearchService`'s debounce, driven by
/// `FakeSyncClock` so no test burns real wall time on the debounce interval.
/// `FakeSyncClock.sleep` returns immediately (recording the requested
/// duration and honoring cancellation), so "the debounce interval elapsed"
/// is observed by waiting for the publish rather than by advancing a gate.
@MainActor
final class ConversationSearchServiceTests: XCTestCase {
    // Revert-check: ConversationSearchService.debounceSearch's
    // `searchDebounceTask?.cancel()` — without cancelling the superseded
    // task, its sleep is recorded on the fake clock and the sleeps
    // assertion below fails.
    func testConversationSearchService_rapidSuccessiveQueries_publishesOnlyLatestQuery() async {
        let clock = FakeSyncClock()
        let service = ConversationSearchService(debounceInterval: 5_000_000, clock: clock)
        var published: [String] = []
        service.onDebouncedSearchTextChange = { [weak service] in
            published.append(service?.debouncedSearchText ?? "")
        }

        // Both assignments land synchronously on the main actor, so the
        // first debounce task is cancelled before its body ever runs: it
        // bails inside `clock.sleep` without recording a sleep and can
        // never publish, no matter when the scheduler runs it.
        service.searchText = "a"
        service.searchText = "ab"

        await waitUntil { service.debouncedSearchText == "ab" }

        XCTAssertEqual(published, ["ab"])
        XCTAssertEqual(clock.sleeps, [5_000_000])
    }

    // Revert-check: the `searchText.isEmpty` fast path in
    // ConversationSearchService.debounceSearch — routing the empty query
    // through the debounce task would leave `debouncedSearchText` at "abc"
    // at the synchronous assertion below and record an extra sleep.
    func testConversationSearchService_emptySearchText_publishesImmediatelyWithoutClockSleep() async {
        let clock = FakeSyncClock()
        let service = ConversationSearchService(debounceInterval: 5_000_000, clock: clock)

        service.searchText = "abc"
        await waitUntil { service.debouncedSearchText == "abc" }
        let sleepCountBeforeClear = clock.sleeps.count

        service.searchText = ""

        // No suspension between the assignment and these assertions: the
        // empty publish must happen synchronously, with no clock sleep.
        XCTAssertEqual(service.debouncedSearchText, "")
        XCTAssertEqual(clock.sleeps.count, sleepCountBeforeClear)
    }

    // Revert-check: `searchDebounceTask?.cancel()` in
    // ConversationSearchService.cleanup() together with the explicit
    // `catch { return }` cancellation bail in debounceSearch. searchText
    // still equals the pending query here, so the stale-query guard would
    // pass — only cancellation keeps the publish from happening, and with
    // FakeSyncClock an uncancelled task publishes within microseconds and
    // trips the inverted expectation.
    func testConversationSearchService_cleanup_cancelsPendingDebounceWithoutPublishing() async {
        let clock = FakeSyncClock()
        let service = ConversationSearchService(debounceInterval: 5_000_000, clock: clock)
        // Inverted expectation: a bounded window in which any publish fails
        // the test. The suite's waitUntil cannot wait on "nothing happens".
        let publishHappened = expectation(description: "cancelled debounce must not publish")
        publishHappened.isInverted = true
        service.onDebouncedSearchTextChange = { publishHappened.fulfill() }

        service.searchText = "doomed"
        service.cleanup()

        await fulfillment(of: [publishHappened], timeout: 1.0)
        XCTAssertEqual(service.debouncedSearchText, "")
        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    // Revert-check: the `guard debouncedSearchText != oldValue` dedupe in
    // ConversationSearchService.debouncedSearchText's didSet — without it
    // the second empty assignment below fires a third callback.
    func testConversationSearchService_duplicateDebouncedValue_firesChangeCallbackOncePerDistinctValue() async {
        let clock = FakeSyncClock()
        let service = ConversationSearchService(debounceInterval: 5_000_000, clock: clock)
        var published: [String] = []
        service.onDebouncedSearchTextChange = { [weak service] in
            published.append(service?.debouncedSearchText ?? "")
        }

        service.searchText = "a"
        await waitUntil { service.debouncedSearchText == "a" }

        // Both empty publishes run synchronously through the fast path; the
        // second assigns the value `debouncedSearchText` already holds, so
        // the didSet dedupe must swallow the callback.
        service.searchText = ""
        service.searchText = ""

        XCTAssertEqual(published, ["a", ""])
    }

    // Copied shape from ConversationLaunchRepairCoordinatorTests. Each
    // caller waits on a positive publish condition; the fake clock makes
    // the debounce complete in microseconds, so the first successful poll
    // normally returns — the deadline is a generous bound, not a pace.
    private func waitUntil(
        timeout: TimeInterval = 30.0,
        pollIntervalNanoseconds: UInt64 = 50_000_000,
        condition: @escaping @MainActor () throws -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if (try? condition()) == true {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}
