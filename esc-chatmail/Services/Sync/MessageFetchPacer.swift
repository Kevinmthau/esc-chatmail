import Foundation

/// Paces `MessageFetcher`'s message GETs across every batch and retry pass
/// of the fetcher that owns it (scalability review step 8, `rate-limit-pacing`).
///
/// Before it, each 50-ID batch fanned out 15 GETs at once with no shared
/// limit: on a large initial sync or recovery that bursts to 50-100 requests
/// a second, 250-500 quota units against Gmail's per-user 250, and the 429s
/// that came back were retried by the same burst.
///
/// Three things pace the fetches.
/// - A token bucket at `requestsPerSecond`, under Gmail's per-user rate
///   (250 units a second, 5 for each `messages.get`). Its burst is one batch,
///   so a sync that fetches a batch now and then never waits on it.
/// - The concurrency of a pass, halved on a 429 and raised by one after as
///   many successes as the limit (AIMD). It returns to the full limit once
///   `quietPeriod` has passed with no 429, so one bad minute does not slow
///   the next sync.
/// - A pause after a 429: no GET starts until the server's Retry-After (or
///   `defaultPause`) has passed.
///
/// Many GETs of one pass can be refused at once: only the first 429 of a
/// pause halves the concurrency, or one burst would take it to 1.
///
/// Deliberately not `GmailAPIClient`'s `RateLimitTracker`: that one trips a
/// breaker on backoff actually slept, and the fetcher's single-attempt GETs
/// sleep none, so N concurrent 429s must not reach it.
actor MessageFetchPacer {
    struct Configuration: Sendable {
        var maxConcurrency = SyncConfig.maxConcurrentMessageFetches
        var requestsPerSecond: Double = 40
        var burst: Double = Double(SyncConfig.messageBatchSize)
        var defaultPause: TimeInterval = 1
        var maxPause: TimeInterval = 60
        var quietPeriod: TimeInterval = 60
    }

    private static let tokenTolerance = 1e-6
    private static let minimumWait: TimeInterval = 0.001

    private let configuration: Configuration
    private let clock: any SyncClock
    private var tokens: Double
    private var lastRefill: Date?
    private var limit: Int
    private var successesSinceRaise = 0
    private var pausedUntil: Date?
    private var lastRateLimitedAt: Date?

    init(configuration: Configuration = Configuration(), clock: any SyncClock = SystemSyncClock()) {
        self.configuration = configuration
        self.clock = clock
        tokens = configuration.burst
        limit = configuration.maxConcurrency
    }

    /// How many GETs a pass may have in flight now.
    var concurrencyLimit: Int {
        restoreAfterQuietPeriod(now: clock.now())
        return limit
    }

    /// The pause outlasts what the caller may wait
    /// (`MessageFetchWaitBudget.maxPauseWait`): the GET is not sent.
    struct PauseOutlastsWait: Error, Equatable {
        let remaining: TimeInterval
    }

    /// Waits for the pause to pass and for a token. Throws
    /// `CancellationError`, or `PauseOutlastsWait` when the pause still has
    /// longer than `maxPauseWait` to run.
    func acquire(maxPauseWait: TimeInterval? = nil) async throws {
        while true {
            try Task.checkCancellation()
            let now = clock.now()
            refill(now: now)
            let pauseRemaining = pausedUntil.map { $0.timeIntervalSince(now) } ?? 0
            if let maxPauseWait, pauseRemaining > maxPauseWait {
                throw PauseOutlastsWait(remaining: pauseRemaining)
            }
            // A refill leaves the count a rounding error short of a whole
            // token; read that as a token.
            let hasToken = tokens >= 1 - Self.tokenTolerance
            if pauseRemaining <= 0, hasToken {
                tokens = max(0, tokens - 1)
                return
            }
            let tokenWait = hasToken ? 0 : (1 - tokens) / configuration.requestsPerSecond
            // Never less than a millisecond: a `Date` near today's time cannot
            // be moved by a nanosecond, so a `FakeSyncClock` asked for one
            // never advanced and this loop spun forever.
            let wait = max(pauseRemaining, tokenWait, Self.minimumWait)
            try await clock.sleep(nanoseconds: UInt64((wait * 1_000_000_000).rounded(.up)))
        }
    }

    func recordSuccess() {
        restoreAfterQuietPeriod(now: clock.now())
        successesSinceRaise += 1
        if successesSinceRaise >= limit {
            limit = min(configuration.maxConcurrency, limit + 1)
            successesSinceRaise = 0
        }
    }

    /// A 429 (or a 403 naming a rate limit): halve the concurrency once per
    /// pause and pause for `retryAfter`, capped at `maxPause`.
    ///
    /// A `retryAfter` of zero or less counts as none, as in
    /// `MessageFetcher.calculateRetryDelay`: `GmailAPIClient` passes a parsed
    /// `Retry-After: 0` through, and a zero pause ended at once, so every 429
    /// of a burst found no pause and halved again, taking 15 to 1.
    func recordRateLimited(retryAfter: TimeInterval?) {
        let now = clock.now()
        let alreadyPaused = pausedUntil.map { now < $0 } ?? false
        if !alreadyPaused {
            limit = max(1, limit / 2)
            successesSinceRaise = 0
        }
        let requested = retryAfter.flatMap { $0 > 0 ? $0 : nil } ?? configuration.defaultPause
        let pause = min(configuration.maxPause, requested)
        let until = now.addingTimeInterval(pause)
        pausedUntil = max(pausedUntil ?? until, until)
        lastRateLimitedAt = now
    }

    private func refill(now: Date) {
        if let lastRefill {
            let elapsed = max(0, now.timeIntervalSince(lastRefill))
            tokens = min(configuration.burst, tokens + elapsed * configuration.requestsPerSecond)
        }
        lastRefill = now
    }

    private func restoreAfterQuietPeriod(now: Date) {
        guard let lastRateLimitedAt,
              now.timeIntervalSince(lastRateLimitedAt) >= configuration.quietPeriod else { return }
        limit = configuration.maxConcurrency
        successesSinceRaise = 0
        self.lastRateLimitedAt = nil
    }
}
