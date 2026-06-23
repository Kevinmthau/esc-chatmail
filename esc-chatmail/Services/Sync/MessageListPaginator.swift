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

struct MessageIDPageStream: Sendable {
    let query: String
    let pageSize: Int
    let messageFetcher: MessageFetcher

    init(
        query: String,
        pageSize: Int = SyncConfig.maxMessagesPerRequest,
        messageFetcher: MessageFetcher
    ) {
        self.query = query
        self.pageSize = pageSize
        self.messageFetcher = messageFetcher
    }

    func forEachPage(
        _ handler: (MessageIDPage) async throws -> Void
    ) async throws {
        var pageToken: String?
        var pageIndex = 0

        repeat {
            try Task.checkCancellation()

            let (messageIds, nextPageToken) = try await messageFetcher.listMessages(
                query: query,
                pageToken: pageToken,
                maxResults: pageSize
            )
            pageIndex += 1

            try await handler(
                MessageIDPage(
                    pageIndex: pageIndex,
                    messageIds: messageIds,
                    nextPageToken: nextPageToken
                )
            )

            pageToken = nextPageToken
        } while pageToken != nil
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
    ///   - progressHandler: Called as batches complete with a cumulative checkpoint
    ///   - messageHandler: Called with each successfully fetched group of messages,
    ///     sorted into chronological order
    ///   - pageCompletion: Called after each listed page is fully processed
    /// - Returns: BatchProcessingResult with success/failure counts
    /// - Throws: Cancellation errors or API errors
    static func fetchAndProcess(
        query: String,
        messageFetcher: MessageFetcher,
        progressHandler: @escaping (PagedSyncCheckpoint) async -> Void,
        messageHandler: @escaping ([GmailMessage]) async -> Void,
        pageCompletion: (() async throws -> Void)? = nil
    ) async throws -> BatchProcessingResult {
        try await fetchAndProcess(
            query: query,
            batchSize: SyncConfig.messageBatchSize,
            messageFetcher: messageFetcher,
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
        progressHandler: @escaping (PagedSyncCheckpoint) async -> Void,
        messageHandler: @escaping ([GmailMessage]) async -> Void,
        pageCompletion: (() async throws -> Void)? = nil
    ) async throws -> BatchProcessingResult {
        var listedCount = 0
        var processedCount = 0
        var successfulCount = 0
        var failedIds: [String] = []

        let stream = MessageIDPageStream(query: query, messageFetcher: messageFetcher)
        try await stream.forEachPage { page in
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
                    try await pageCompletion()
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
                await messageHandler(messages)
            }

            processedCount += pageResult.totalProcessed
            successfulCount += pageResult.successfulCount
            failedIds.append(contentsOf: pageResult.failedIds)

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
                try await pageCompletion()
            }
        }

        return BatchProcessingResult(
            totalProcessed: processedCount,
            successfulCount: successfulCount,
            failedIds: failedIds
        )
    }
}
