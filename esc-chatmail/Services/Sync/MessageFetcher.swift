import Foundation

// Note: SyncConfig is defined in Constants.swift

/// Result of a bounded concurrency fetch operation
private struct BoundedFetchResult {
    let successfulMessages: [GmailMessage]
    let retriableFailedIds: [String]
    /// Messages that failed with message-scoped, non-retriable errors other
    /// than 404 (malformed payloads and other request-specific 4xx responses).
    let permanentlyFailedIds: [String]
    /// Messages the server reported as not found — they no longer exist server-side
    let notFoundIds: [String]
    /// Messages that failed with retriable errors but we've exhausted retries
    /// These might succeed on a future sync attempt
    let exhaustedRetryIds: [String]
    /// Largest server-provided Retry-After (seconds, capped) among rate-limited
    /// failures in this pass — the outer retry loop honors it over synthetic backoff.
    let maxRetryAfterSeconds: TimeInterval?
    /// Whether any GET of this pass was refused for a rate limit: the retry
    /// that follows waits on the rate-limit ladder, not the transient one.
    let sawRateLimit: Bool
    /// Set when Gmail reported an account-scoped condition during this pass.
    /// The pass stops issuing requests and the affected IDs appear in no
    /// failure bucket: authentication, revoked credentials, and quota
    /// exhaustion are run-level outcomes, never per-message verdicts.
    let runAbortError: APIError?
}

/// Outcome of a batch fetch-and-persist pass: fetch failures that must block
/// cursor advancement, server-side-gone IDs (non-blocking), and the per-ID
/// persistence report from the persist callback.
struct MessageBatchOutcome: Sendable {
    /// Transient-exhausted and non-retriable fetch failures (excluding 404s).
    let fetchFailedIds: [String]
    /// The server returned 404 — the message no longer exists remotely.
    let goneIds: [String]
    let persistence: MessagePersistenceReport

    static let empty = MessageBatchOutcome(fetchFailedIds: [], goneIds: [], persistence: .empty)

    /// IDs whose outcome must prevent the history cursor from advancing.
    var blockingFailureIds: [String] { fetchFailedIds + persistence.failedIds }
    var hasBlockingFailures: Bool { !fetchFailedIds.isEmpty || !persistence.failedIds.isEmpty }
}

/// Outcome of a single retry pass over previously abandoned messages
struct AbandonedRetryFetchResult {
    let fetched: [GmailMessage]
    /// The server returned 404 — the message no longer exists server-side
    let goneIds: [String]
    /// Failed for any other reason — worth retrying on a future sync
    let failedIds: [String]

    static let empty = AbandonedRetryFetchResult(fetched: [], goneIds: [], failedIds: [])
}

/// Handles fetching messages from the Gmail API with retry logic and timeout handling
final class MessageFetcher: @unchecked Sendable {
    private let apiClient: any GmailAPIClientProtocol
    private let clock: any SyncClock

    /// Maximum number of retry attempts for failed messages
    private let maxRetryAttempts = 3

    /// Base delay in nanoseconds for exponential backoff (500ms)
    private let baseRetryDelay: UInt64 = 500_000_000

    /// The waits before each retry of a pass that was rate limited, in
    /// seconds: 50 in all, against Gmail's per-user limit window. The
    /// transient ladder (0.5, 1 and 2 seconds) ended inside one window, and
    /// an ID still limited on the last pass is a blocking failure that holds
    /// the cursor (scalability review step 8, `rate-limit-pacing`).
    static let rateLimitedRetryDelays: [TimeInterval] = [5, 15, 30]

    /// Paces every message GET of this fetcher (`MessageFetchPacer`). One
    /// fetcher serves a `SyncEngine`'s every sync, so its pacing carries
    /// from one batch, pass and run to the next.
    let pacer: MessageFetchPacer

    @MainActor init() {
        self.apiClient = GmailAPIClient.shared
        self.clock = SystemSyncClock()
        self.pacer = MessageFetchPacer(clock: clock)
    }

    init(
        apiClient: any GmailAPIClientProtocol,
        clock: any SyncClock = SystemSyncClock(),
        pacer: MessageFetchPacer? = nil
    ) {
        self.apiClient = apiClient
        self.clock = clock
        self.pacer = pacer ?? MessageFetchPacer(clock: clock)
    }

    /// Checks if an error is retriable (transient network/server issues)
    private func isRetriableError(_ error: Error) -> Bool {
        // URLError codes that are retriable
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }

        // APIError decisions come from the canonical mapping on the type.
        if let apiError = error as? APIError {
            return apiError.isRetriableSameRequest
        }

        // NSError timeout codes using URLError constants for clarity
        if let nsError = error as NSError? {
            if nsError.domain == NSURLErrorDomain {
                // Map error codes to URLError equivalents for clarity:
                // -1001 = .timedOut, -1009 = .notConnectedToInternet,
                // -1004 = .cannotConnectToHost, -1005 = .networkConnectionLost
                return [URLError.timedOut.rawValue, URLError.notConnectedToInternet.rawValue,
                        URLError.cannotConnectToHost.rawValue, URLError.networkConnectionLost.rawValue].contains(nsError.code)
            }
        }

        // Default to non-retriable for unknown errors to avoid infinite retry loops
        return false
    }

    /// Errors whose outcome says nothing about an individual message. Letting
    /// them enter the permanent-ID bucket would spend the history escape hatch
    /// and eventually delete abandoned recovery pointers during an account
    /// outage.
    private func accountScopedAbortError(_ error: Error) -> APIError? {
        guard let apiError = error as? APIError,
              apiError.isAccountScopedSyncAbort else { return nil }
        return apiError
    }

    /// Fetches messages with bounded concurrency to prevent resource exhaustion.
    /// - Parameters:
    ///   - ids: Array of message IDs to fetch
    ///   - isFinalAttempt: If true, retriable failures go to exhaustedRetryIds instead of retriableFailedIds
    /// - Returns: Result containing successful messages and categorized failures
    private func fetchWithBoundedConcurrency(
        ids: [String],
        isFinalAttempt: Bool = false
    ) async throws -> BoundedFetchResult {
        try Task.checkCancellation()

        var successfulMessages: [GmailMessage] = []
        var retriableFailedIds: [String] = []
        var permanentlyFailedIds: [String] = []
        var notFoundIds: [String] = []
        var exhaustedRetryIds: [String] = []
        var maxRetryAfterSeconds: TimeInterval?
        var sawRateLimit = false
        var runAbortError: APIError?
        let pacer = self.pacer
        let maxPauseWait = MessageFetchWaitBudget.current.maxPauseWait

        await withTaskGroup(of: (String, Result<GmailMessage, Error>).self) { group in
            var iterator = ids.makeIterator()
            var activeTasks = 0

            // Single retry owner: this class owns the retry policy, so the
            // client gets a budget of ONE total attempt per call (a successful
            // 401 token refresh grants its replacement attempt inside the
            // client and never consumes the budget). The previous stack —
            // client loop × 15s withTimeout wrapper × this class's loop —
            // allowed up to 12 HTTP attempts per message, and the 15s wrapper
            // amputated the client's backoff mid-sleep anyway (URLSession's
            // per-request timeout is already forced ≥30s).
            //
            // Every GET waits for the pacer first and reports to it after.
            // A cancelled `acquire` is the end of the pass, never a verdict.
            // A pause longer than the run may wait (an app refresh's
            // `MessageFetchWaitBudget`) fails the GET unsent as rate limited,
            // which no server said, so the pacer is not told of it.
            @Sendable func fetchOnce(_ id: String) async -> (String, Result<GmailMessage, Error>) {
                do {
                    try Task.checkCancellation()
                    try await pacer.acquire(maxPauseWait: maxPauseWait)
                } catch let refusal as MessageFetchPacer.PauseOutlastsWait {
                    return (id, .failure(APIError.rateLimited(retryAfter: refusal.remaining)))
                } catch {
                    return (id, .failure(error))
                }
                do {
                    let message = try await self.apiClient.getMessage(id: id, format: "full", maxRetries: 1)
                    await pacer.recordSuccess()
                    return (id, .success(message))
                } catch {
                    if case APIError.rateLimited(let retryAfter) = error {
                        await pacer.recordRateLimited(retryAfter: retryAfter)
                    }
                    return (id, .failure(error))
                }
            }

            // Starts GETs up to the pacer's current concurrency, which a 429
            // in this pass lowers before the next one starts.
            func startTasksUpToLimit() async {
                let limit = await pacer.concurrencyLimit
                while activeTasks < limit, let id = iterator.next() {
                    group.addTask { await fetchOnce(id) }
                    activeTasks += 1
                }
            }

            await startTasksUpToLimit()

            // Process results and start new tasks as others complete
            for await (id, result) in group {
                if Task.isCancelled {
                    // Cancel all remaining child tasks when parent is cancelled
                    group.cancelAll()
                    break
                }

                activeTasks -= 1

                switch result {
                case .success(let message):
                    successfulMessages.append(message)
                case .failure(let error):
                    if let accountError = self.accountScopedAbortError(error) {
                        // Account-scoped: every further request this pass is
                        // doomed, so stop issuing them and give the affected
                        // IDs no verdict. An auth or quota outage must never
                        // be recorded as a per-message failure.
                        if runAbortError == nil {
                            runAbortError = accountError
                            group.cancelAll()
                        }
                    } else if runAbortError == nil {
                        if case APIError.rateLimited(let retryAfter) = error {
                            sawRateLimit = true
                            if let retryAfter {
                                maxRetryAfterSeconds = max(maxRetryAfterSeconds ?? 0, retryAfter)
                            }
                        }
                        if self.isRetriableError(error) {
                            // Transient error (timeout, network, 5xx)
                            if isFinalAttempt {
                                // We've exhausted retries, but this might succeed on future sync
                                exhaustedRetryIds.append(id)
                            } else {
                                retriableFailedIds.append(id)
                            }
                        } else if case APIError.notFound = error {
                            // The server says the message doesn't exist
                            notFoundIds.append(id)
                        } else {
                            // Message-scoped non-retriable error (4xx or
                            // decoding) — safe to classify for this ID.
                            permanentlyFailedIds.append(id)
                        }
                    }
                    // Failures arriving after an account-scoped abort are
                    // cancellations of in-flight tasks; those IDs also get
                    // no verdict.
                }

                // Start more if there are more IDs and the pass was not
                // aborted by an account-scoped condition.
                if runAbortError == nil {
                    await startTasksUpToLimit()
                }
            }
        }

        // Child requests deliberately report errors as values so quota and
        // per-message failures can be classified together. Parent-task
        // cancellation is different: an incomplete ID partition must never
        // look like a successful batch and let a history cursor/checkpoint
        // advance.
        try Task.checkCancellation()

        return BoundedFetchResult(
            successfulMessages: successfulMessages,
            retriableFailedIds: retriableFailedIds,
            permanentlyFailedIds: permanentlyFailedIds,
            notFoundIds: notFoundIds,
            exhaustedRetryIds: exhaustedRetryIds,
            maxRetryAfterSeconds: maxRetryAfterSeconds,
            sawRateLimit: sawRateLimit,
            runAbortError: runAbortError
        )
    }

    /// Sorts messages oldest-first for persistence; the persister expects pre-sorted input.
    /// internalDate is milliseconds since epoch as a string; nil sorts to beginning.
    private func chronologicallySorted(_ messages: [GmailMessage]) -> [GmailMessage] {
        messages.sorted {
            ($0.internalDate ?? "0") < ($1.internalDate ?? "0")
        }
    }

    /// Sorts messages by internalDate and hands the whole batch to the persister in
    /// chronological order. Persisting as a batch lets the persister parallelize the
    /// expensive per-message processing while keeping writes ordered.
    private func persistInChronologicalOrder(
        _ messages: [GmailMessage],
        persist: @escaping @Sendable ([GmailMessage]) async throws -> MessagePersistenceReport
    ) async throws -> MessagePersistenceReport {
        guard !messages.isEmpty else { return .empty }
        return try await persist(chronologicallySorted(messages))
    }

    /// Makes a single fetch attempt for previously abandoned messages, classifying
    /// each ID so the caller can decide whether to keep retrying it on future syncs.
    /// No in-place retry loop: these IDs have already failed multiple full syncs, so
    /// one attempt per sync is enough.
    ///
    /// An account-scoped abort mid-pass throws and yields no outcome for the
    /// affected IDs. Recording it would burn the drain's retry budget on
    /// attempts that prove nothing about the messages.
    func fetchAbandonedMessages(_ ids: [String]) async throws -> AbandonedRetryFetchResult {
        guard !ids.isEmpty, !Task.isCancelled else { return .empty }

        let result: BoundedFetchResult
        do {
            result = try await fetchWithBoundedConcurrency(ids: ids, isFinalAttempt: true)
        } catch is CancellationError {
            return .empty
        } catch {
            throw error
        }

        // A cancelled pass classifies unreliably (child tasks fail with
        // CancellationError); record nothing rather than burn retry budget
        // on attempts that never ran.
        guard !Task.isCancelled else { return .empty }

        if let runAbortError = result.runAbortError {
            throw runAbortError
        }

        return AbandonedRetryFetchResult(
            fetched: chronologicallySorted(result.successfulMessages),
            goneIds: result.notFoundIds,
            failedIds: result.permanentlyFailedIds + result.retriableFailedIds + result.exhaustedRetryIds
        )
    }

    /// Fetches a batch of messages by ID with automatic retry on failure
    /// - Parameters:
    ///   - ids: Array of Gmail message IDs to fetch
    ///   - persist: Callback invoked with each successfully fetched group of messages,
    ///     sorted into chronological order; returns the per-ID persistence report
    /// - Returns: The batch outcome: blocking fetch failures, server-side-gone
    ///   IDs (404 — non-blocking), and the merged persistence report
    /// - Throws: An account-scoped authentication, credential, or quota error
    ///   when Gmail reports one — the sync run must abort: affected IDs get no
    ///   per-message verdict (in neither the outcome nor the report), so the
    ///   next scheduled sync retries them after the quota window resets
    ///   instead of recording permanent failures. Errors thrown by `persist`
    ///   also propagate. Cancellation always throws so a partial ID partition
    ///   cannot advance durable sync progress.
    func fetchBatch(
        _ ids: [String],
        persist: @escaping @Sendable ([GmailMessage]) async throws -> MessagePersistenceReport
    ) async throws -> MessageBatchOutcome {
        try Task.checkCancellation()

        var permanentlyFailed: [String] = []
        var exhaustedRetries: [String] = []
        var goneIds: [String] = []
        var persistenceReport = MessagePersistenceReport()

        // First attempt
        let initialResult = try await fetchWithBoundedConcurrency(ids: ids)
        permanentlyFailed.append(contentsOf: initialResult.permanentlyFailedIds)
        goneIds.append(contentsOf: initialResult.notFoundIds)

        for id in initialResult.permanentlyFailedIds {
            Log.warning("Non-retriable error for message \(Log.hashIdentifier(id))", category: .sync)
        }

        persistenceReport.merge(
            try await persistInChronologicalOrder(initialResult.successfulMessages, persist: persist)
        )
        try Task.checkCancellation()

        // Abort after persisting what did succeed: classifying the remainder
        // would turn an account-scoped condition into per-message verdicts.
        if let runAbortError = initialResult.runAbortError {
            throw runAbortError
        }

        var currentFailedIds = initialResult.retriableFailedIds
        var pendingRetryAfter = initialResult.maxRetryAfterSeconds
        var pendingRateLimit = initialResult.sawRateLimit
        let waitBudget = MessageFetchWaitBudget.current

        // Retry loop with exponential backoff and jitter
        for attempt in 1...maxRetryAttempts {
            guard !currentFailedIds.isEmpty else { break }
            try Task.checkCancellation()

            // A run that cannot wait out a rate limit (an app refresh) ends
            // the retries of a rate-limited pass here: its IDs are blocking
            // failures that hold the cursor, and what was fetched is saved.
            if pendingRateLimit, !waitBudget.retriesRateLimitedPasses {
                Log.info("Rate limited with no time to wait it out; leaving \(currentFailedIds.count) messages to the next sync", category: .sync)
                exhaustedRetries.append(contentsOf: currentFailedIds)
                currentFailedIds = []
                break
            }

            // Server-provided Retry-After (when the previous pass was rate
            // limited) dominates the synthetic backoff.
            let delay = calculateRetryDelay(
                attempt: attempt,
                retryAfter: pendingRetryAfter,
                rateLimited: pendingRateLimit
            )
            Log.debug("Retry attempt \(attempt)/\(maxRetryAttempts) for \(currentFailedIds.count) failed messages after \(delay / 1_000_000)ms...", category: .sync)

            try await clock.sleep(nanoseconds: delay)
            try Task.checkCancellation()

            let isFinalAttempt = attempt == maxRetryAttempts
            let retryResult = try await fetchWithBoundedConcurrency(
                ids: currentFailedIds,
                isFinalAttempt: isFinalAttempt
            )

            for message in retryResult.successfulMessages {
                Log.debug("Successfully fetched message \(Log.hashIdentifier(message.id)) on retry attempt \(attempt)", category: .sync)
            }

            for id in retryResult.permanentlyFailedIds {
                Log.warning("Permanently failed to fetch message \(Log.hashIdentifier(id)) after \(attempt) attempts", category: .sync)
            }

            permanentlyFailed.append(contentsOf: retryResult.permanentlyFailedIds)
            goneIds.append(contentsOf: retryResult.notFoundIds)
            exhaustedRetries.append(contentsOf: retryResult.exhaustedRetryIds)
            persistenceReport.merge(
                try await persistInChronologicalOrder(retryResult.successfulMessages, persist: persist)
            )
            try Task.checkCancellation()

            if let runAbortError = retryResult.runAbortError {
                throw runAbortError
            }

            currentFailedIds = retryResult.retriableFailedIds
            pendingRetryAfter = retryResult.maxRetryAfterSeconds
            pendingRateLimit = retryResult.sawRateLimit
        }

        // Log exhausted retries separately - these might succeed on next sync
        if !exhaustedRetries.isEmpty {
            Log.info("Messages with transient failures after \(maxRetryAttempts) retries (may succeed on next sync): \(exhaustedRetries.count)", category: .sync)
        }

        // Blocking failures are permanent fetch errors PLUS exhausted transient
        // failures — both must prevent historyId advancement. Server-side 404s
        // are reported separately: a message deleted remotely has a terminal
        // outcome and must not freeze the cursor.
        if !permanentlyFailed.isEmpty {
            Log.warning("Total permanently failed messages (non-retriable errors): \(permanentlyFailed.count)", category: .sync)
        }
        if !exhaustedRetries.isEmpty {
            Log.warning("Total transient failures exhausted retries: \(exhaustedRetries.count)", category: .sync)
        }
        if !goneIds.isEmpty {
            Log.info("Messages gone server-side (404): \(goneIds.count)", category: .sync)
        }

        try Task.checkCancellation()

        return MessageBatchOutcome(
            fetchFailedIds: permanentlyFailed + exhaustedRetries,
            goneIds: goneIds,
            persistence: persistenceReport
        )
    }

    /// Fetches messages from Gmail API using pagination
    /// - Parameters:
    ///   - query: Gmail search query
    ///   - pageToken: Optional page token for pagination
    ///   - maxResults: Maximum number of results per page
    /// - Returns: Tuple of message IDs and next page token (if any)
    func listMessages(
        query: String,
        pageToken: String? = nil,
        maxResults: Int = SyncConfig.maxMessagesPerRequest
    ) async throws -> (messageIds: [String], nextPageToken: String?) {
        let response = try await apiClient.listMessages(
            pageToken: pageToken,
            maxResults: maxResults,
            query: query
        )

        let messageIds = response.messages?.map { $0.id } ?? []
        return (messageIds, response.nextPageToken)
    }

    /// One page of a search over every label, Spam and Trash included
    /// (`GmailAPIClientProtocol.searchAllMessages`).
    func searchAllMessages(
        query: String,
        maxResults: Int
    ) async throws -> (messageIds: [String], nextPageToken: String?) {
        let response = try await apiClient.searchAllMessages(query: query, maxResults: maxResults)
        return (response.messages?.map { $0.id } ?? [], response.nextPageToken)
    }

    /// Fetches history records from Gmail API
    /// - Parameters:
    ///   - startHistoryId: Starting history ID
    ///   - pageToken: Optional page token for pagination
    ///   - maxResults: Optional cap on history records per page (nil = server default)
    /// - Returns: Tuple of history records, latest history ID, and next page token
    func listHistory(
        startHistoryId: String,
        pageToken: String? = nil,
        maxResults: Int? = nil
    ) async throws -> (history: [HistoryRecord]?, historyId: String?, nextPageToken: String?) {
        let response = try await apiClient.listHistory(
            startHistoryId: startHistoryId,
            pageToken: pageToken,
            maxResults: maxResults
        )

        return (response.history, response.historyId, response.nextPageToken)
    }

    /// Fetches user profile from Gmail API
    func getProfile() async throws -> GmailProfile {
        return try await apiClient.getProfile()
    }

    /// Fetches Gmail metadata for a single message.
    ///
    /// Paced like the full GETs (`MessageFetchPacer`): label reconciliation
    /// makes about one of these for each recent message, against the same
    /// per-user limit. The client keeps its own retries here (no
    /// `maxRetries: 1`), so only the 429 it finally throws reaches the pacer;
    /// the backoff it sleeps before that is what its `RateLimitTracker`
    /// records, as before. A pause longer than the run may wait throws
    /// `APIError.rateLimited` without sending the GET.
    func getMessageMetadata(id: String) async throws -> GmailMessage {
        do {
            try await pacer.acquire(maxPauseWait: MessageFetchWaitBudget.current.maxPauseWait)
        } catch let refusal as MessageFetchPacer.PauseOutlastsWait {
            throw APIError.rateLimited(retryAfter: refusal.remaining)
        }
        do {
            let message = try await apiClient.getMessage(id: id, format: "metadata")
            await pacer.recordSuccess()
            return message
        } catch {
            if case APIError.rateLimited(let retryAfter) = error {
                await pacer.recordRateLimited(retryAfter: retryAfter)
            }
            throw error
        }
    }

    /// Fetches send-as aliases from Gmail API
    func listSendAs() async throws -> [SendAs] {
        return try await apiClient.listSendAs()
    }

    /// Fetches all labels from Gmail API
    func listLabels() async throws -> [GmailLabel] {
        return try await apiClient.listLabels()
    }

    // MARK: - Private Helpers

    /// Calculates retry delay with exponential backoff and jitter to prevent thundering herd.
    ///
    /// A server-provided Retry-After (already capped by the API client)
    /// dominates the synthetic backoff — the 0.5/1/2s ladder used to ignore
    /// it entirely, hammering a rate-limited server ahead of its own
    /// schedule. Jitter adds 0-25% randomness either way, spreading retries
    /// when multiple operations fail simultaneously.
    ///
    /// - Parameters:
    ///   - attempt: The current retry attempt number (1-based)
    ///   - retryAfter: Server-requested pacing in seconds, if any
    /// - Returns: Delay in nanoseconds
    private func calculateRetryDelay(
        attempt: Int,
        retryAfter: TimeInterval? = nil,
        rateLimited: Bool = false
    ) -> UInt64 {
        // Base exponential backoff: 500ms, 1s, 2s, etc. A rate-limited pass
        // waits on the longer ladder instead.
        let syntheticDelay: UInt64
        if rateLimited {
            let ladder = Self.rateLimitedRetryDelays
            let seconds = ladder[min(max(attempt - 1, 0), ladder.count - 1)]
            syntheticDelay = UInt64(seconds * 1_000_000_000)
        } else {
            syntheticDelay = baseRetryDelay * UInt64(1 << (attempt - 1))
        }
        let baseDelay: UInt64
        if let retryAfter, retryAfter > 0 {
            baseDelay = max(syntheticDelay, UInt64(retryAfter * 1_000_000_000))
        } else {
            baseDelay = syntheticDelay
        }

        // Add 0-25% jitter to prevent thundering herd
        let jitter = UInt64.random(in: 0...(baseDelay / 4))

        return baseDelay + jitter
    }
}
// Note: withTimeout function is defined in GmailAPIClient.swift
