import Foundation

// Note: SyncConfig is defined in Constants.swift

/// Result of a bounded concurrency fetch operation
private struct BoundedFetchResult {
    let successfulMessages: [GmailMessage]
    let retriableFailedIds: [String]
    /// Messages that failed with non-retriable errors other than 404 (auth, 4xx, decoding)
    let permanentlyFailedIds: [String]
    /// Messages the server reported as not found — they no longer exist server-side
    let notFoundIds: [String]
    /// Messages that failed with retriable errors but we've exhausted retries
    /// These might succeed on a future sync attempt
    let exhaustedRetryIds: [String]
    /// Largest server-provided Retry-After (seconds, capped) among rate-limited
    /// failures in this pass — the outer retry loop honors it over synthetic backoff.
    let maxRetryAfterSeconds: TimeInterval?
    /// Set when Gmail reported the account's quota exhausted during this pass.
    /// The pass stops issuing requests and the affected IDs appear in no
    /// failure bucket: quota exhaustion is account-scoped, never a
    /// per-message verdict.
    let quotaError: APIError?
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

    @MainActor init() {
        self.apiClient = GmailAPIClient.shared
        self.clock = SystemSyncClock()
    }

    init(apiClient: any GmailAPIClientProtocol, clock: any SyncClock = SystemSyncClock()) {
        self.apiClient = apiClient
        self.clock = clock
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

    /// Fetches messages with bounded concurrency to prevent resource exhaustion.
    /// - Parameters:
    ///   - ids: Array of message IDs to fetch
    ///   - isFinalAttempt: If true, retriable failures go to exhaustedRetryIds instead of retriableFailedIds
    /// - Returns: Result containing successful messages and categorized failures
    private func fetchWithBoundedConcurrency(
        ids: [String],
        isFinalAttempt: Bool = false
    ) async -> BoundedFetchResult {
        var successfulMessages: [GmailMessage] = []
        var retriableFailedIds: [String] = []
        var permanentlyFailedIds: [String] = []
        var notFoundIds: [String] = []
        var exhaustedRetryIds: [String] = []
        var maxRetryAfterSeconds: TimeInterval?
        var quotaError: APIError?

        await withTaskGroup(of: (String, Result<GmailMessage, Error>).self) { group in
            var iterator = ids.makeIterator()
            var activeTasks = 0
            let maxConcurrent = SyncConfig.maxConcurrentMessageFetches

            // Single retry owner: this class owns the retry policy, so the
            // client gets a budget of ONE total attempt per call (a successful
            // 401 token refresh grants its replacement attempt inside the
            // client and never consumes the budget). The previous stack —
            // client loop × 15s withTimeout wrapper × this class's loop —
            // allowed up to 12 HTTP attempts per message, and the 15s wrapper
            // amputated the client's backoff mid-sleep anyway (URLSession's
            // per-request timeout is already forced ≥30s).
            @Sendable func fetchOnce(_ id: String) async -> (String, Result<GmailMessage, Error>) {
                do {
                    try Task.checkCancellation()
                    let message = try await self.apiClient.getMessage(id: id, format: "full", maxRetries: 1)
                    return (id, .success(message))
                } catch {
                    return (id, .failure(error))
                }
            }

            // Start initial batch of concurrent tasks
            while activeTasks < maxConcurrent, let id = iterator.next() {
                group.addTask { await fetchOnce(id) }
                activeTasks += 1
            }

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
                    if let apiError = error as? APIError, case .quotaExhausted = apiError {
                        // Account-scoped: every further request this pass is
                        // doomed, so stop issuing them and give the affected
                        // IDs no verdict — quota exhaustion must never be
                        // recorded as a per-message failure.
                        if quotaError == nil {
                            quotaError = apiError
                            group.cancelAll()
                        }
                    } else if quotaError == nil {
                        if case APIError.rateLimited(let retryAfter) = error, let retryAfter {
                            maxRetryAfterSeconds = max(maxRetryAfterSeconds ?? 0, retryAfter)
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
                            // Non-retriable error (4xx, auth, decoding) - truly permanent
                            permanentlyFailedIds.append(id)
                        }
                    }
                    // Failures arriving after the quota signal are the
                    // cancellations of in-flight tasks; those IDs also get
                    // no verdict.
                }

                // Start next task if there are more IDs (and the pass wasn't
                // aborted by quota exhaustion)
                if quotaError == nil, let nextId = iterator.next() {
                    group.addTask { await fetchOnce(nextId) }
                    activeTasks += 1
                }
            }
        }

        return BoundedFetchResult(
            successfulMessages: successfulMessages,
            retriableFailedIds: retriableFailedIds,
            permanentlyFailedIds: permanentlyFailedIds,
            notFoundIds: notFoundIds,
            exhaustedRetryIds: exhaustedRetryIds,
            maxRetryAfterSeconds: maxRetryAfterSeconds,
            quotaError: quotaError
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
    /// Quota exhaustion mid-pass yields no outcome for the affected IDs — like
    /// the cancellation path below, recording it would burn the drain's retry
    /// budget on attempts that prove nothing about the messages.
    func fetchAbandonedMessages(_ ids: [String]) async -> AbandonedRetryFetchResult {
        guard !ids.isEmpty, !Task.isCancelled else { return .empty }

        let result = await fetchWithBoundedConcurrency(ids: ids, isFinalAttempt: true)

        // A cancelled pass classifies unreliably (child tasks fail with
        // CancellationError); record nothing rather than burn retry budget
        // on attempts that never ran.
        guard !Task.isCancelled else { return .empty }

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
    /// - Throws: `APIError.quotaExhausted` when Gmail reports the account's
    ///   quota exhausted — the sync run must abort: the affected IDs get no
    ///   per-message verdict (in neither the outcome nor the report), so the
    ///   next scheduled sync retries them after the quota window resets
    ///   instead of recording permanent failures. Errors thrown by `persist`
    ///   also propagate.
    func fetchBatch(
        _ ids: [String],
        persist: @escaping @Sendable ([GmailMessage]) async throws -> MessagePersistenceReport
    ) async throws -> MessageBatchOutcome {
        guard !Task.isCancelled else {
            Log.debug("Batch processing cancelled", category: .sync)
            return MessageBatchOutcome(fetchFailedIds: ids, goneIds: [], persistence: .empty)
        }

        var permanentlyFailed: [String] = []
        var exhaustedRetries: [String] = []
        var goneIds: [String] = []
        var persistenceReport = MessagePersistenceReport()

        // First attempt
        let initialResult = await fetchWithBoundedConcurrency(ids: ids)
        permanentlyFailed.append(contentsOf: initialResult.permanentlyFailedIds)
        goneIds.append(contentsOf: initialResult.notFoundIds)

        for id in initialResult.permanentlyFailedIds {
            Log.warning("Non-retriable error for message \(Log.hashIdentifier(id))", category: .sync)
        }

        persistenceReport.merge(
            try await persistInChronologicalOrder(initialResult.successfulMessages, persist: persist)
        )

        // Abort after persisting what did succeed: classifying the remainder
        // would turn an account-scoped condition into per-message verdicts.
        if let quotaError = initialResult.quotaError {
            throw quotaError
        }

        var currentFailedIds = initialResult.retriableFailedIds
        var pendingRetryAfter = initialResult.maxRetryAfterSeconds

        // Retry loop with exponential backoff and jitter
        for attempt in 1...maxRetryAttempts {
            guard !Task.isCancelled, !currentFailedIds.isEmpty else {
                break
            }

            // Server-provided Retry-After (when the previous pass was rate
            // limited) dominates the synthetic backoff.
            let delay = calculateRetryDelay(attempt: attempt, retryAfter: pendingRetryAfter)
            Log.debug("Retry attempt \(attempt)/\(maxRetryAttempts) for \(currentFailedIds.count) failed messages after \(delay / 1_000_000)ms...", category: .sync)

            do {
                try await clock.sleep(nanoseconds: delay)
            } catch {
                // Task was cancelled during sleep
                break
            }

            guard !Task.isCancelled else { break }

            let isFinalAttempt = attempt == maxRetryAttempts
            let retryResult = await fetchWithBoundedConcurrency(ids: currentFailedIds, isFinalAttempt: isFinalAttempt)

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

            if let quotaError = retryResult.quotaError {
                throw quotaError
            }

            currentFailedIds = retryResult.retriableFailedIds
            pendingRetryAfter = retryResult.maxRetryAfterSeconds
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

    /// Fetches history records from Gmail API
    /// - Parameters:
    ///   - startHistoryId: Starting history ID
    ///   - pageToken: Optional page token for pagination
    /// - Returns: Tuple of history records, latest history ID, and next page token
    func listHistory(
        startHistoryId: String,
        pageToken: String? = nil
    ) async throws -> (history: [HistoryRecord]?, historyId: String?, nextPageToken: String?) {
        let response = try await apiClient.listHistory(
            startHistoryId: startHistoryId,
            pageToken: pageToken
        )

        return (response.history, response.historyId, response.nextPageToken)
    }

    /// Fetches user profile from Gmail API
    func getProfile() async throws -> GmailProfile {
        return try await apiClient.getProfile()
    }

    /// Fetches Gmail metadata for a single message.
    func getMessageMetadata(id: String) async throws -> GmailMessage {
        try await apiClient.getMessage(id: id, format: "metadata")
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
    private func calculateRetryDelay(attempt: Int, retryAfter: TimeInterval? = nil) -> UInt64 {
        // Base exponential backoff: 500ms, 1s, 2s, etc.
        let syntheticDelay = baseRetryDelay * UInt64(1 << (attempt - 1))
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
