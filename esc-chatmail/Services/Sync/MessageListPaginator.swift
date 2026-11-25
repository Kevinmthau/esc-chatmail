import Foundation

struct MessageIDPage: Equatable, Sendable {
    let pageIndex: Int
    let messageIds: [String]
    let nextPageToken: String?

    var hasMorePages: Bool {
        nextPageToken != nil
    }
}

struct PagedSyncCheckpoint: Equatable, Sendable {
    let pageIndex: Int
    let listedCount: Int
    let processedCount: Int
    let successfulCount: Int
    let failedCount: Int
    let nextPageToken: String?

    var isComplete: Bool {
        nextPageToken == nil
    }
}

/// What `MessageListPaginator` reports after each listed page is processed:
/// the page to list next and the attempt's cumulative failures so far.
struct MessageListPageProgress: Equatable, Sendable {
    let nextPageToken: String?
    let fetchFailedIds: [String]
    let persistenceFailedIds: [String]
    let resolvedTrackedIds: Set<String>
}

struct MessageIDPageStream: Sendable {
    let query: String
    let pageSize: Int
    let messageFetcher: MessageFetcher
    /// The page an interrupted attempt stopped before (`PagedSyncProgress`);
    /// nil lists from the first page.
    let startPageToken: String?

    init(
        query: String,
        pageSize: Int = SyncConfig.maxMessagesPerRequest,
        messageFetcher: MessageFetcher,
        startPageToken: String? = nil
    ) {
        self.query = query
        self.pageSize = pageSize
        self.messageFetcher = messageFetcher
        self.startPageToken = startPageToken
    }

    /// Lists every page from `startPageToken`, or from the first page.
    ///
    /// A stored page token is opaque, days old at most
    /// (`SyncConfig.pagedSyncResumeMaxAge`), and nobody has measured how
    /// Gmail answers one it no longer honors. So the stored token is given
    /// up once, and the listing starts again from its first page, wherever
    /// trusting it could be wrong: a deterministic refusal of it (any 4xx
    /// but an account-scoped or rate-limit one, `refusesStoredPageToken`),
    /// or a first page that comes back empty and last, which an expired
    /// token answered that way would make a clean end of a listing that
    /// never reached its later pages. What the earlier attempt saved stays
    /// saved and its failures ride in the caller's progress; starting again
    /// costs the window's pages listed and fetched again, as before resume
    /// existed. Transient and account-scoped failures propagate, and so does
    /// anything on a token Gmail itself just handed out.
    func forEachPage(
        _ handler: (MessageIDPage) async throws -> Void
    ) async throws {
        var pageToken = startPageToken
        var pageIndex = 0

        /// Whether this list call was of the stored token, which may be
        /// given up (once: giving it up sets the token to nil).
        func isListingStoredToken() -> Bool {
            pageIndex == 0 && startPageToken != nil && pageToken == startPageToken
        }

        // Not `repeat … while pageToken != nil`: giving up the stored token
        // sets it to nil and continues, which that condition would end.
        while true {
            try Task.checkCancellation()

            let messageIds: [String]
            let nextPageToken: String?
            do {
                (messageIds, nextPageToken) = try await messageFetcher.listMessages(
                    query: query,
                    pageToken: pageToken,
                    maxResults: pageSize
                )
            } catch let error as APIError {
                guard isListingStoredToken(), Self.refusesStoredPageToken(error) else {
                    throw error
                }
                Log.warning(
                    "Stored message-list page token was refused; listing again from the first page",
                    category: .sync
                )
                pageToken = nil
                continue
            }

            if isListingStoredToken(), messageIds.isEmpty, nextPageToken == nil {
                Log.warning(
                    "Stored message-list page token listed nothing and ended the listing; listing again from the first page",
                    category: .sync
                )
                pageToken = nil
                continue
            }
            pageIndex += 1

            try await handler(
                MessageIDPage(
                    pageIndex: pageIndex,
                    messageIds: messageIds,
                    nextPageToken: nextPageToken
                )
            )

            guard let nextPageToken else { break }
            pageToken = nextPageToken
        }
    }

    /// Whether `error` refuses the request itself, the same way every time,
    /// rather than the account (authentication, revoked credentials, quota)
    /// or the moment (a rate limit, a 5xx, a timeout, the network). The
    /// client raises `invalidData` for a 4xx it has no case for (and a 403
    /// that names neither a rate limit nor a quota) and `notFound` for a 404.
    static func refusesStoredPageToken(_ error: APIError) -> Bool {
        switch error {
        case .invalidData, .notFound, .invalidURL, .invalidHistoryPageToken:
            return true
        case .networkError, .decodingError, .authenticationError, .credentialsRevoked,
             .rateLimited, .quotaExhausted, .serverError, .timeout, .historyIdExpired:
            return false
        }
    }
}

/// Handles paginated message list fetching from Gmail API.
///
/// Foreground initial sync and history recovery must not collect every message
/// ID before processing. This paginator streams pages into the batch processor so
/// very large mailboxes can make durable progress page by page.
struct MessageListPaginator {

    /// Streams and processes all messages matching a query with progress tracking.
    ///
    /// - Parameters:
    ///   - query: Gmail search query
    ///   - messageFetcher: The fetcher to use for API calls
    ///   - trackedIds: IDs whose resolution the caller needs back (the
    ///     deferred ledger), reported in `resolvedTrackedIds`
    ///   - progressHandler: Called as batches complete with a cumulative checkpoint
    ///   - messageHandler: Called with each successfully fetched group of messages,
    ///     sorted into chronological order
    ///   - startPageToken: The page an interrupted attempt stopped before;
    ///     nil lists from the first page
    ///   - pageCompletion: Called after each listed page is fully processed,
    ///     with the page to list next and this call's cumulative failures, for
    ///     the caller to stage into the save that commits the page
    /// - Returns: BatchProcessingResult with success/failure counts; only the
    ///   failure buckets and the resolved tracked IDs keep their IDs
    /// - Throws: Cancellation errors or API errors
    static func fetchAndProcess(
        query: String,
        messageFetcher: MessageFetcher,
        trackedIds: Set<String> = [],
        startPageToken: String? = nil,
        progressHandler: @escaping (PagedSyncCheckpoint) async -> Void,
        messageHandler: @escaping @Sendable ([GmailMessage]) async throws -> MessagePersistenceReport,
        pageCompletion: ((MessageListPageProgress) async throws -> Void)? = nil
    ) async throws -> BatchProcessingResult {
        try await fetchAndProcess(
            query: query,
            batchSize: SyncConfig.messageBatchSize,
            messageFetcher: messageFetcher,
            trackedIds: trackedIds,
            startPageToken: startPageToken,
            progressHandler: progressHandler,
            messageHandler: messageHandler,
            pageCompletion: pageCompletion
        )
    }

    /// Streams and processes messages with a custom batch size.
    static func fetchAndProcess(
        query: String,
        batchSize: Int,
        messageFetcher: MessageFetcher,
        trackedIds: Set<String> = [],
        startPageToken: String? = nil,
        progressHandler: @escaping (PagedSyncCheckpoint) async -> Void,
        messageHandler: @escaping @Sendable ([GmailMessage]) async throws -> MessagePersistenceReport,
        pageCompletion: ((MessageListPageProgress) async throws -> Void)? = nil
    ) async throws -> BatchProcessingResult {
        var listedCount = 0
        var processedCount = 0
        var successfulCount = 0
        var failedIds: [String] = []
        var persistenceFailures = MessagePersistenceReport()
        var resolvedTrackedIds = Set<String>()

        let stream = MessageIDPageStream(
            query: query,
            messageFetcher: messageFetcher,
            startPageToken: startPageToken
        )
        try await stream.forEachPage { page in
            func pageProgress() -> MessageListPageProgress {
                MessageListPageProgress(
                    nextPageToken: page.nextPageToken,
                    fetchFailedIds: failedIds,
                    persistenceFailedIds: persistenceFailures.failedIds,
                    resolvedTrackedIds: resolvedTrackedIds
                )
            }

            listedCount += page.messageIds.count

            guard !page.messageIds.isEmpty else {
                await progressHandler(
                    PagedSyncCheckpoint(
                        pageIndex: page.pageIndex,
                        listedCount: listedCount,
                        processedCount: processedCount,
                        successfulCount: successfulCount,
                        failedCount: failedIds.count,
                        nextPageToken: page.nextPageToken
                    )
                )
                if let pageCompletion {
                    try await pageCompletion(pageProgress())
                }
                return
            }

            let pageResult = try await BatchProcessor.processMessages(
                messageIds: page.messageIds,
                batchSize: batchSize,
                messageFetcher: messageFetcher
            ) { pageProcessed, _ in
                await progressHandler(
                    PagedSyncCheckpoint(
                        pageIndex: page.pageIndex,
                        listedCount: listedCount,
                        processedCount: processedCount + pageProcessed,
                        successfulCount: successfulCount,
                        failedCount: failedIds.count,
                        nextPageToken: page.nextPageToken
                    )
                )
            } messageHandler: { messages in
                try await messageHandler(messages)
            }

            processedCount += pageResult.totalProcessed
            successfulCount += pageResult.successfulCount
            failedIds.append(contentsOf: pageResult.failedIds)
            persistenceFailures.merge(pageResult.persistence.retainingOnlyFailures)
            if !trackedIds.isEmpty {
                for resolved in [
                    pageResult.persistence.persistedIds,
                    pageResult.persistence.excludedIds,
                    pageResult.persistence.unprocessableIds,
                    pageResult.goneIds
                ] {
                    resolvedTrackedIds.formUnion(resolved.lazy.filter(trackedIds.contains))
                }
            }

            await progressHandler(
                PagedSyncCheckpoint(
                    pageIndex: page.pageIndex,
                    listedCount: listedCount,
                    processedCount: processedCount,
                    successfulCount: successfulCount,
                    failedCount: failedIds.count,
                    nextPageToken: page.nextPageToken
                )
            )

            if let pageCompletion {
                try await pageCompletion(pageProgress())
            }
        }

        return BatchProcessingResult(
            totalProcessed: processedCount,
            successfulCount: successfulCount,
            failedIds: failedIds,
            persistence: persistenceFailures,
            resolvedTrackedIds: resolvedTrackedIds
        )
    }
}
