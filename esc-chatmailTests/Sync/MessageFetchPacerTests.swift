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
