import XCTest
@testable import esc_chatmail

/// Shared 429 pacing of message GETs (scalability review step 8,
/// `rate-limit-pacing`): the pacer alone on a `FakeSyncClock`, the fetcher's
/// concurrency under a sustained 429, and the rate-limit retry ladder against
/// the real `GmailAPIClient` through `StubURLProtocol`.
final class MessageFetchPacerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - The pacer

    /// A burst of 429s from one pass halves the concurrency once, not once
    /// for each refused GET; successes raise it by one a round; a quiet
    /// period restores the full limit.
    ///
    /// Revert-check: halve on every 429 in
    /// `MessageFetchPacer.recordRateLimited` (drop the `alreadyPaused`
    /// guard) and three 429s take 16 to 2.
    func testRateLimited_halvesOncePerPauseAndRecovers() async {
        let clock = FakeSyncClock()
        let pacer = MessageFetchPacer(configuration: configuration(maxConcurrency: 16), clock: clock)

        await pacer.recordRateLimited(retryAfter: 5)
        await pacer.recordRateLimited(retryAfter: 5)
        await pacer.recordRateLimited(retryAfter: 5)
        let halved = await pacer.concurrencyLimit
        XCTAssertEqual(halved, 8)

        for _ in 0..<8 { await pacer.recordSuccess() }
        let raised = await pacer.concurrencyLimit
        XCTAssertEqual(raised, 9, "One more after a round of successes")

        clock.advance(by: 61)
        let restored = await pacer.concurrencyLimit
        XCTAssertEqual(restored, 16, "A minute with no 429 restores the full limit")
    }

    /// `Retry-After: 0` (which `GmailAPIClient` passes through as 0) is no
    /// Retry-After: the default pause applies, so a burst of such 429s
    /// halves the concurrency once, not once for each.
    ///
    /// Revert-check: pause for `max(retryAfter ?? defaultPause, 0)` in
    /// `MessageFetchPacer.recordRateLimited` and three 429s take 16 to 2.
    func testRateLimited_retryAfterZero_halvesOncePerPause() async throws {
        let clock = FakeSyncClock()
        let pacer = MessageFetchPacer(configuration: configuration(maxConcurrency: 16), clock: clock)

        await pacer.recordRateLimited(retryAfter: 0)
        await pacer.recordRateLimited(retryAfter: 0)
        await pacer.recordRateLimited(retryAfter: -1)
        let limit = await pacer.concurrencyLimit
        XCTAssertEqual(limit, 8)

        try await pacer.acquire()
        let slept = Double(clock.sleeps.reduce(0, +)) / 1_000_000_000
        XCTAssertEqual(slept, MessageFetchPacer.Configuration().defaultPause, accuracy: 0.01)
    }

    /// A pause longer than the caller may wait is not waited: the acquire
    /// throws at once.
    ///
    /// Revert-check: ignore `maxPauseWait` in `MessageFetchPacer.acquire`
    /// and it sleeps the 30 seconds.
    func testAcquire_pauseLongerThanTheWait_throwsWithoutWaiting() async throws {
        let clock = FakeSyncClock()
        let pacer = MessageFetchPacer(configuration: configuration(), clock: clock)
        await pacer.recordRateLimited(retryAfter: 30)

        do {
            try await pacer.acquire(maxPauseWait: 2)
            XCTFail("A 30-second pause outlasts a 2-second wait")
        } catch let refusal as MessageFetchPacer.PauseOutlastsWait {
            XCTAssertEqual(refusal.remaining, 30, accuracy: 0.01)
        }
        XCTAssertTrue(clock.sleeps.isEmpty)

        try await pacer.acquire(maxPauseWait: 31)
        let slept = Double(clock.sleeps.reduce(0, +)) / 1_000_000_000
        XCTAssertEqual(slept, 30, accuracy: 0.01, "Positive control: a pause inside the wait is waited")
    }

    /// No GET starts until a 429's Retry-After has passed.
    ///
    /// Revert-check: ignore `pausedUntil` in `MessageFetchPacer.acquire`
    /// and the acquire returns without sleeping.
    func testAcquire_waitsOutTheRetryAfterPause() async throws {
        let clock = FakeSyncClock()
        let pacer = MessageFetchPacer(configuration: configuration(), clock: clock)

        await pacer.recordRateLimited(retryAfter: 7)
        try await pacer.acquire()

        let slept = clock.sleeps.reduce(0, +)
        XCTAssertEqual(Double(slept) / 1_000_000_000, 7, accuracy: 0.01)
    }

    /// GETs beyond the burst wait for the bucket at the configured rate.
    ///
    /// Revert-check: return from `MessageFetchPacer.acquire` without taking
    /// a token and the tenth acquire does not wait.
    func testAcquire_beyondTheBurst_waitsForTheRate() async throws {
        let clock = FakeSyncClock()
        let pacer = MessageFetchPacer(
            configuration: configuration(requestsPerSecond: 4, burst: 8),
            clock: clock
        )

        for _ in 0..<8 { try await pacer.acquire() }
        XCTAssertTrue(clock.sleeps.isEmpty, "The burst needs no wait")

        try await pacer.acquire()
        try await pacer.acquire()
        let slept = Double(clock.sleeps.reduce(0, +)) / 1_000_000_000
        XCTAssertEqual(slept, 0.5, accuracy: 0.01, "Two more at four a second")
    }

    // MARK: - The fetcher

    /// After a pass's GETs are refused with 429, the retry pass has fewer in
    /// flight at once.
    ///
    /// Revert-check: start tasks up to `SyncConfig.maxConcurrentMessageFetches`
    /// in place of `pacer.concurrencyLimit` in
    /// `MessageFetcher.fetchWithBoundedConcurrency` and the retry pass runs
    /// 15 at once.
    func testFetchBatch_sustained429_reducesInFlightConcurrency() async throws {
        let ids = (0..<30).map { "m\($0)" }
        let gate = RateLimitedThenSlow(refusals: 15)
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageOperation = { id, _ in
            try await gate.fetch(id)
        }
        let fetcher = MessageFetcher(apiClient: mockAPI, clock: FakeSyncClock())

        let outcome = try await fetcher.fetchBatch(ids) { _ in .empty }

        XCTAssertTrue(outcome.fetchFailedIds.isEmpty, "Positive control: every ID is fetched on retry")
        let firstPassPeak = await gate.peakWhileRefusing
        let retryPeak = await gate.peakAfterRefusing
        XCTAssertEqual(firstPassPeak, SyncConfig.maxConcurrentMessageFetches)
        XCTAssertLessThanOrEqual(
            retryPeak, SyncConfig.maxConcurrentMessageFetches / 2 + 1,
            "The retry pass must not fan out at the full concurrency into the same limit"
        )
    }

    /// A rate-limited message is retried for longer than Gmail's per-user
    /// limit window lasts: against a limit that ends 10 seconds after it
    /// began, the transient ladder (3.5 seconds in all) ended inside it and
    /// left the ID a blocking failure that held the cursor.
    ///
    /// Revert-check: use the transient ladder for a rate-limited pass in
    /// `MessageFetcher.calculateRetryDelay` (pass `rateLimited: false`) and
    /// "m1" is a fetch failure.
    func testFetchBatch_rateLimitLadder_outlastsATenSecondLimitWindow() async throws {
        let clock = FakeSyncClock()
        let limitEnds = clock.now().addingTimeInterval(10)
        let body = Data(#"{"id":"m1","threadId":"t1"}"#.utf8)
        StubURLProtocol.responder = { _ in
            clock.now() < limitEnds ? .status(429) : .data(200, body)
        }
        let client = GmailAPIClient(
            tokenManager: MockTokenManager(),
            retryStrategy: NetworkRetryStrategy(maxRetries: 3, initialDelay: 0.01, maxDelay: 0.02),
            session: StubURLProtocol.makeSession()
        )
        let fetcher = MessageFetcher(apiClient: client, clock: clock)

        let outcome = try await fetcher.fetchBatch(["m1"]) { messages in
            var report = MessagePersistenceReport()
            for message in messages { report.record(message.id, .persisted) }
            return report
        }

        XCTAssertTrue(outcome.fetchFailedIds.isEmpty, "The ladder must outlast the limit window")
        XCTAssertEqual(outcome.persistence.persistedIds, ["m1"])
        XCTAssertGreaterThanOrEqual(StubURLProtocol.requestCount, 2, "Positive control: the first GET was refused")
    }

    /// Under an app refresh's budget a rate-limited pass is not retried:
    /// the refused ID is a blocking failure at once, the rest are saved, and
    /// nothing sleeps. Before step 8 the short ladder ended in seconds; the
    /// 50-second ladder outlasted the refresh's half minute.
    ///
    /// Revert-check: drop the `retriesRateLimitedPasses` check from the
    /// retry loop of `MessageFetcher.fetchBatch` and it sleeps 50 seconds
    /// and more.
    func testFetchBatch_appRefreshBudget_endsARateLimitedBatchWithoutWaiting() async throws {
        let mockAPI = MockGmailAPIClient()
        let okMessage = GmailMessageBuilder().withId("ok").build()
        // "limited" is refused only once "ok" has been sent: refused first,
        // its pause would keep "ok" from being sent at all.
        mockAPI.getMessageOperation = OkSentBeforeLimited.operation(ok: ("ok", okMessage))
        let clock = FakeSyncClock()
        let fetcher = MessageFetcher(apiClient: mockAPI, clock: clock)

        let outcome = try await MessageFetchWaitBudget.$current.withValue(.appRefresh) {
            try await fetcher.fetchBatch(["ok", "limited"]) { messages in
                var report = MessagePersistenceReport()
                for message in messages { report.record(message.id, .persisted) }
                return report
            }
        }

        XCTAssertEqual(outcome.fetchFailedIds, ["limited"])
        XCTAssertEqual(outcome.persistence.persistedIds, ["ok"])
        XCTAssertTrue(clock.sleeps.isEmpty, "Nothing is waited out")
        XCTAssertEqual(mockAPI.getMessageCalledIds.filter { $0 == "limited" }.count, 1)
    }

    /// Under an app refresh's budget a GET whose pause outlasts its wait is
    /// not sent and fails as rate limited, a blocking failure; the pacer is
    /// not told of a 429 no server sent.
    ///
    /// Revert-check: call `pacer.acquire()` with no `maxPauseWait` in
    /// `MessageFetcher.fetchWithBoundedConcurrency` and the GET is sent
    /// after the 30-second pause.
    func testFetchBatch_appRefreshBudget_sendsNothingDuringALongPause() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageResponses["m1"] = GmailMessageBuilder().withId("m1").build()
        let clock = FakeSyncClock()
        let fetcher = MessageFetcher(apiClient: mockAPI, clock: clock)
        await fetcher.pacer.recordRateLimited(retryAfter: 30)
        let limitAfterThe429 = await fetcher.pacer.concurrencyLimit

        let outcome = try await MessageFetchWaitBudget.$current.withValue(.appRefresh) {
            try await fetcher.fetchBatch(["m1"]) { _ in .empty }
        }

        XCTAssertEqual(outcome.fetchFailedIds, ["m1"])
        XCTAssertTrue(mockAPI.getMessageCalledIds.isEmpty, "No GET is sent during the pause")
        XCTAssertTrue(clock.sleeps.isEmpty)
        let limit = await fetcher.pacer.concurrencyLimit
        XCTAssertEqual(limit, limitAfterThe429, "An unsent GET is no 429 to halve for")
    }

    /// Under an app refresh's budget a sustained limit with no Retry-After
    /// (the pacer's one-second default pause) ends the pass at once: the
    /// GETs not yet sent are not sent. With a second's allowance each of
    /// them waited the pause, was sent and was refused again, one at a time,
    /// and a batch of 50 outlasted the refresh.
    ///
    /// Revert-check: give `MessageFetchWaitBudget.appRefresh` a
    /// `maxPauseWait` of 2 and the batch sleeps a second for each GET after
    /// the first wave.
    func testFetchBatch_appRefreshBudget_sustainedLimitWithoutRetryAfter_sendsNoMore() async throws {
        let ids = (0..<50).map { "m\($0)" }
        let mockAPI = MockGmailAPIClient()
        for id in ids { mockAPI.getMessageErrors[id] = APIError.rateLimited(retryAfter: nil) }
        let clock = FakeSyncClock()
        let fetcher = MessageFetcher(apiClient: mockAPI, clock: clock)

        let outcome = try await MessageFetchWaitBudget.$current.withValue(.appRefresh) {
            try await fetcher.fetchBatch(ids) { _ in .empty }
        }

        XCTAssertEqual(Set(outcome.fetchFailedIds), Set(ids), "Every ID is a blocking failure")
        let slept = Double(clock.sleeps.reduce(0, +)) / 1_000_000_000
        XCTAssertLessThan(slept, 1, "No pause is waited")
        XCTAssertLessThanOrEqual(
            mockAPI.getMessageCalledIds.count, SyncConfig.maxConcurrentMessageFetches,
            "Only the first wave is sent"
        )
    }

    /// Label reconciliation's metadata GETs are paced like the full ones:
    /// one waits out the pause, and a 429 it ends with pauses the others.
    ///
    /// Revert-check: call the client directly in
    /// `MessageFetcher.getMessageMetadata` (no `pacer.acquire`) and the
    /// first GET does not wait.
    func testGetMessageMetadata_isPaced() async throws {
        let mockAPI = MockGmailAPIClient()
        mockAPI.getMessageResponses["m1"] = GmailMessageBuilder().withId("m1").build()
        mockAPI.getMessageErrors["m2"] = APIError.rateLimited(retryAfter: 4)
        let clock = FakeSyncClock()
        let fetcher = MessageFetcher(apiClient: mockAPI, clock: clock)
        await fetcher.pacer.recordRateLimited(retryAfter: 7)

        _ = try await fetcher.getMessageMetadata(id: "m1")
        let slept = Double(clock.sleeps.reduce(0, +)) / 1_000_000_000
        XCTAssertEqual(slept, 7, accuracy: 0.01, "The metadata GET waits for the pause")

        clock.advance(by: 61)
        let restored = await fetcher.pacer.concurrencyLimit
        XCTAssertEqual(restored, SyncConfig.maxConcurrentMessageFetches, "Positive control: the limit is back")
        do {
            _ = try await fetcher.getMessageMetadata(id: "m2")
            XCTFail("m2 is refused")
        } catch APIError.rateLimited {
            // Expected.
        }
        let limit = await fetcher.pacer.concurrencyLimit
        XCTAssertEqual(limit, SyncConfig.maxConcurrentMessageFetches / 2, "Its 429 reaches the pacer")
    }

    private func configuration(
        maxConcurrency: Int = 15,
        requestsPerSecond: Double = 1_000,
        burst: Double = 1_000
    ) -> MessageFetchPacer.Configuration {
        var configuration = MessageFetchPacer.Configuration()
        configuration.maxConcurrency = maxConcurrency
        configuration.requestsPerSecond = requestsPerSecond
        configuration.burst = burst
        return configuration
    }
}

/// Refuses the first `refusals` GETs with a 429, then answers each after a
/// short real wait, recording the peak number in flight in each phase.
private actor RateLimitedThenSlow {
    private let refusals: Int
    private var started = 0
    private var inFlight = 0
    private(set) var peakWhileRefusing = 0
    private(set) var peakAfterRefusing = 0

    init(refusals: Int) {
        self.refusals = refusals
    }

    func fetch(_ id: String) async throws -> GmailMessage {
        started += 1
        let refusing = started <= refusals
        inFlight += 1
        if refusing {
            peakWhileRefusing = max(peakWhileRefusing, inFlight)
        } else {
            peakAfterRefusing = max(peakAfterRefusing, inFlight)
        }
        // A real wait so the GETs of a pass overlap: the first pass's are
        // all started before any answers.
        try await Task.sleep(nanoseconds: 20_000_000)
        inFlight -= 1
        if refusing {
            throw APIError.rateLimited(retryAfter: nil)
        }
        return GmailMessageBuilder().withId(id).build()
    }
}

