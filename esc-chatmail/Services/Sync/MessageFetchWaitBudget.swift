import Foundation

/// How long `MessageFetcher` may wait out a rate limit in the sync that is
/// running (scalability review step 8, `rate-limit-pacing`).
///
/// A sync with time to spare waits: a rate-limited pass retries on
/// `MessageFetcher.rateLimitedRetryDelays` (50 seconds in all) and a GET
/// waits for the pacer's pause, up to its 60. An app refresh has about half
/// a minute, and a wait that outlasted it expired the task and cancelled the
/// run before its save, dropping every message the slice had fetched; under
/// a sustained limit every refresh did the same. So an app refresh waits out
/// no rate limit: a pass that was rate limited is not retried, its IDs still
/// failing are blocking failures that hold the cursor, and the run saves
/// what it fetched. A GET whose pause is longer than `maxPauseWait` is not
/// sent and fails as rate limited.
///
/// The orchestrator sets it for its run (`IncrementalSyncOrchestrator.performSync`),
/// as a task-local value, so it reaches every GET of the run, the child
/// tasks of a fetch pass included, without a parameter on every call on
/// the way. Outside a run it is `.standard`.
struct MessageFetchWaitBudget: Equatable, Sendable {
    /// Whether a pass that was rate limited is retried on the rate-limit
    /// ladder. False ends the batch's retries there.
    let retriesRateLimitedPasses: Bool
    /// The longest a GET waits for the pacer's pause before it is sent; nil
    /// waits the whole pause.
    let maxPauseWait: TimeInterval?

    static let standard = MessageFetchWaitBudget(retriesRateLimitedPasses: true, maxPauseWait: nil)

    /// No pause is waited, not even the pacer's one-second default for a
    /// 429 with no Retry-After (Gmail's usual answer): with any allowance at
    /// all, a sustained limit refused the GETs of a pass one at a time, each
    /// after waiting that second, and a batch of 50 outlasted the refresh.
    static let appRefresh = MessageFetchWaitBudget(retriesRateLimitedPasses: false, maxPauseWait: 0)

    @TaskLocal static var current: MessageFetchWaitBudget = .standard
}
