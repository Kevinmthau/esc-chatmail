import Foundation
import CoreData

struct SyncReconciliationDiagnostics: Sendable, Equatable {
    var missedMessageCandidatesChecked = 0
    var missedMessagesFound = 0
    var labelMessagesChecked = 0
    var skippedChecks = 0
    var metadataFetchFailures = 0
    var driftFound = 0
    var driftRepaired = 0
    var cappedReconciliation = false
    var cappedAtMessageCount = 0
    var resumedMissedMessageWindow = false

    var messagesChecked: Int {
        missedMessageCandidatesChecked + labelMessagesChecked
    }

    var hasWarnings: Bool {
        metadataFetchFailures > 0 || cappedReconciliation
    }

    var hasFindings: Bool {
        missedMessagesFound > 0 || skippedChecks > 0 || driftFound > 0 || driftRepaired > 0
    }

    var summary: String {
        [
            "messagesChecked=\(messagesChecked)",
            "missedChecked=\(missedMessageCandidatesChecked)",
            "missedFound=\(missedMessagesFound)",
            "labelChecked=\(labelMessagesChecked)",
            "skipped=\(skippedChecks)",
            "metadataFailures=\(metadataFetchFailures)",
            "driftFound=\(driftFound)",
            "driftRepaired=\(driftRepaired)",
            "capped=\(cappedReconciliation)",
            "cappedAt=\(cappedAtMessageCount)",
            "resumedMissedWindow=\(resumedMissedMessageWindow)"
        ].joined(separator: " ")
    }

    mutating func merge(_ other: SyncReconciliationDiagnostics) {
        missedMessageCandidatesChecked += other.missedMessageCandidatesChecked
        missedMessagesFound += other.missedMessagesFound
        labelMessagesChecked += other.labelMessagesChecked
        skippedChecks += other.skippedChecks
        metadataFetchFailures += other.metadataFetchFailures
        driftFound += other.driftFound
        driftRepaired += other.driftRepaired
        cappedReconciliation = cappedReconciliation || other.cappedReconciliation
        cappedAtMessageCount = max(cappedAtMessageCount, other.cappedAtMessageCount)
        resumedMissedMessageWindow = resumedMissedMessageWindow || other.resumedMissedMessageWindow
    }
}

struct MissedMessageReconciliationResult: Sendable, Equatable {
    let missingIds: [String]
    let diagnostics: SyncReconciliationDiagnostics
}

enum LabelReconciliationOutcome: Sendable, Equatable {
    case notRequested
    case completed
    case incomplete
}

struct LabelReconciliationResult: Sendable, Equatable {
    let diagnostics: SyncReconciliationDiagnostics
    let outcome: LabelReconciliationOutcome
}

/// Handles reconciliation between Gmail and local state
///
/// Responsibilities:
/// - Detect and fetch missed messages
/// - Reconcile label states (especially INBOX for archive detection)
/// - Verify local state matches Gmail truth
final class SyncReconciliation: Sendable {

    private let messageFetcher: MessageFetcher
    private let failureTracker: SyncFailureTracker
    private let log = LogCategory.sync.logger

    init(
        messageFetcher: MessageFetcher,
        failureTracker: SyncFailureTracker = .shared
    ) {
        self.messageFetcher = messageFetcher
        self.failureTracker = failureTracker
    }

    // MARK: - Missed Message Detection

    /// Checks for messages that might have been missed by history sync
    /// - Parameters:
    ///   - context: Core Data context to check against
    ///   - installTimestamp: App install timestamp to avoid fetching pre-install messages
    /// - Returns: Message IDs that exist in Gmail but not locally
    func checkForMissedMessages(
        in context: NSManagedObjectContext,
        installTimestamp: TimeInterval
    ) async -> [String] {
        await checkForMissedMessagesWithDiagnostics(
            in: context,
            installTimestamp: installTimestamp
        ).missingIds
    }

    func checkForMissedMessagesWithDiagnostics(
        in context: NSManagedObjectContext,
        installTimestamp: TimeInterval
    ) async -> MissedMessageReconciliationResult {
        var diagnostics = SyncReconciliationDiagnostics()

        do {
            let reconciliationStartTime = calculateReconciliationStartTime(installTimestamp: installTimestamp)
            let epochSeconds = Int(reconciliationStartTime.timeIntervalSince1970)

            let query = "after:\(epochSeconds) -label:spam -label:drafts -label:trash"

            // Scale the reconciliation budget based on time since last sync and
            // page through results up to a bounded cap so we can recover missed
            // mail beyond the first results page on busy accounts.
            let timeSinceStart = Date().timeIntervalSince(reconciliationStartTime)
            let maxMessagesToCheck = min(
                SyncConfig.maxReconciliationMessages,
                max(
                    SyncConfig.minimumReconciliationMessages,
                    Int(timeSinceStart / 3600) * 50
                )
            )

            let fetchResult = try await fetchRecentMessageIds(
                query: query,
                maxCount: maxMessagesToCheck
            )
            diagnostics.missedMessageCandidatesChecked = fetchResult.ids.count
            diagnostics.cappedReconciliation = fetchResult.wasCapped
            diagnostics.cappedAtMessageCount = fetchResult.wasCapped ? fetchResult.ids.count : 0
            diagnostics.resumedMissedMessageWindow = fetchResult.resumedFromCursor

            guard !fetchResult.ids.isEmpty else {
                log.debug("No recent messages to check for reconciliation")
                return MissedMessageReconciliationResult(missingIds: [], diagnostics: diagnostics)
            }

            log.debug("Checking \(fetchResult.ids.count) recent Gmail messages against local DB")

            let missingIds = await findMissingMessages(ids: fetchResult.ids, in: context)
            diagnostics.missedMessagesFound = missingIds.count

            if !missingIds.isEmpty {
                log.info("Found \(missingIds.count) messages in Gmail but not locally")
            }

            return MissedMessageReconciliationResult(missingIds: missingIds, diagnostics: diagnostics)
        } catch {
            log.error("Reconciliation check failed", error: error)
            return MissedMessageReconciliationResult(missingIds: [], diagnostics: diagnostics)
        }
    }

    private struct RecentMessageIDFetchResult {
        let ids: [String]
        let wasCapped: Bool
        let resumedFromCursor: Bool
    }

    private func fetchRecentMessageIds(query: String, maxCount: Int) async throws -> RecentMessageIDFetchResult {
        guard maxCount > 0 else {
            return RecentMessageIDFetchResult(ids: [], wasCapped: false, resumedFromCursor: false)
        }

        let pendingCursors = loadMissedMessageReconciliationCursors()
        let effectiveMaxCount = reconciliationBudget(maxCount, hasPendingCursor: !pendingCursors.isEmpty)

        if !pendingCursors.isEmpty {
            return try await fetchRecentMessageIdsResuming(
                cursors: pendingCursors,
                currentQuery: query,
                maxCount: effectiveMaxCount
            )
        }

        let fetchResult = try await fetchMessageIdWindow(
            query: query,
            startPageToken: nil,
            maxCount: effectiveMaxCount
        )
        saveMissedMessageReconciliationCursor(
            query: query,
            nextPageToken: fetchResult.nextPageToken,
            startedAt: Date().timeIntervalSince1970
        )

        if fetchResult.nextPageToken != nil {
            log.warning(
                "Reconciliation capped at \(fetchResult.ids.count) recent messages; remaining pages will be checked on a later sync"
            )
        }

        return RecentMessageIDFetchResult(
            ids: fetchResult.ids,
            wasCapped: fetchResult.nextPageToken != nil,
            resumedFromCursor: false
        )
    }

    private struct MessageIDWindowFetchResult {
        let ids: [String]
        let nextPageToken: String?
    }

    private func fetchMessageIdWindow(
        query: String,
        startPageToken: String?,
        maxCount: Int
    ) async throws -> MessageIDWindowFetchResult {
        guard maxCount > 0 else {
            return MessageIDWindowFetchResult(ids: [], nextPageToken: startPageToken)
        }

        var pageToken = startPageToken
        var collectedIds: [String] = []
        var seenIds = Set<String>()

        repeat {
            let remaining = maxCount - collectedIds.count
            guard remaining > 0 else { break }

            let pageSize = min(SyncConfig.reconciliationPageSize, remaining)
            let (messageIds, nextPageToken) = try await messageFetcher.listMessages(
                query: query,
                pageToken: pageToken,
                maxResults: pageSize
            )

            for id in messageIds where seenIds.insert(id).inserted {
                collectedIds.append(id)
            }

            pageToken = nextPageToken
        } while pageToken != nil && collectedIds.count < maxCount

        return MessageIDWindowFetchResult(ids: collectedIds, nextPageToken: pageToken)
    }

    private func fetchRecentMessageIdsResuming(
        cursors: [MissedMessageReconciliationCursor],
        currentQuery: String,
        maxCount: Int
    ) async throws -> RecentMessageIDFetchResult {
        let newestPageCount = min(SyncConfig.reconciliationPageSize, maxCount)
        let newestWindow = try await fetchMessageIdWindow(
            query: currentQuery,
            startPageToken: nil,
            maxCount: newestPageCount
        )
        let remaining = maxCount - newestWindow.ids.count
        let currentOverflowCursor = newestWindow.nextPageToken.flatMap { nextPageToken in
            cursors.contains(where: { $0.query == currentQuery }) ? nil : MissedMessageReconciliationCursor(
                query: currentQuery,
                pageToken: nextPageToken,
                startedAt: Date().timeIntervalSince1970
            )
        }

        guard remaining > 0 else {
            saveMissedMessageReconciliationCursors(cursors + [currentOverflowCursor].compactMap { $0 })
            return RecentMessageIDFetchResult(
                ids: newestWindow.ids,
                wasCapped: true,
                resumedFromCursor: false
            )
        }

        var ids = newestWindow.ids
        var remainingBudget = remaining
        var cursorsToSave: [MissedMessageReconciliationCursor] = []

        for index in cursors.indices {
            let cursor = cursors[index]
            guard remainingBudget > 0 else {
                cursorsToSave.append(contentsOf: cursors[index...])
                break
            }

            let resumedWindow: MessageIDWindowFetchResult
            do {
                resumedWindow = try await fetchMessageIdWindow(
                    query: cursor.query,
                    startPageToken: cursor.pageToken,
                    maxCount: remainingBudget
                )
            } catch {
                let nextIndex = cursors.index(after: index)
                let remainingCursors = nextIndex < cursors.endIndex ? cursors[nextIndex...] : cursors[cursors.endIndex...]
                saveResumeCursorsAfterResumeFailure(
                    error: error,
                    priorCursors: Array(cursors[..<index]),
                    failedCursor: cursor,
                    remainingCursors: remainingCursors,
                    currentOverflowCursor: currentOverflowCursor
                )
                throw error
            }

            ids = combinedUniqueIds(ids, resumedWindow.ids)
            remainingBudget -= resumedWindow.ids.count

            if let nextPageToken = resumedWindow.nextPageToken {
                cursorsToSave.append(
                    MissedMessageReconciliationCursor(
                        query: cursor.query,
                        pageToken: nextPageToken,
                        startedAt: cursor.startedAt
                    )
                )
            }
        }

        if let currentOverflowCursor {
            cursorsToSave.append(currentOverflowCursor)
        }
        saveMissedMessageReconciliationCursors(cursorsToSave)

        if !cursorsToSave.isEmpty {
            log.warning(
                "Reconciliation resumed and capped at \(ids.count) recent messages; remaining pages will be checked on a later sync"
            )
        } else {
            log.debug("Reconciliation completed pending missed-message window")
        }

        return RecentMessageIDFetchResult(
            ids: ids,
            wasCapped: !cursorsToSave.isEmpty,
            resumedFromCursor: true
        )
    }

    private func saveResumeCursorsAfterResumeFailure(
        error: Error,
        priorCursors: [MissedMessageReconciliationCursor],
        failedCursor: MissedMessageReconciliationCursor,
        remainingCursors: ArraySlice<MissedMessageReconciliationCursor>,
        currentOverflowCursor: MissedMessageReconciliationCursor?
    ) {
        var cursorsToSave = priorCursors
        if !isInvalidReconciliationCursorError(error) {
            cursorsToSave.append(failedCursor)
        }
        cursorsToSave.append(contentsOf: remainingCursors)
        if let currentOverflowCursor {
            cursorsToSave.append(currentOverflowCursor)
        }
        saveMissedMessageReconciliationCursors(cursorsToSave)
    }

    private func reconciliationBudget(_ baseCount: Int, hasPendingCursor: Bool) -> Int {
        guard hasPendingCursor else { return baseCount }

        let minimumResumeBudget = SyncConfig.minimumReconciliationMessages + SyncConfig.reconciliationPageSize
        return min(SyncConfig.maxReconciliationMessages, max(baseCount, minimumResumeBudget))
    }

    private func combinedUniqueIds(_ first: [String], _ second: [String]) -> [String] {
        var seen = Set<String>()
        var combined: [String] = []
        combined.reserveCapacity(first.count + second.count)

        for id in first + second where seen.insert(id).inserted {
            combined.append(id)
        }

        return combined
    }

    private struct MissedMessageReconciliationCursor: Codable {
        let query: String
        let pageToken: String
        let startedAt: TimeInterval
    }

    private func loadMissedMessageReconciliationCursors() -> [MissedMessageReconciliationCursor] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: SyncConfig.missedMessageReconciliationCursorKey) else {
            return []
        }

        do {
            let decoder = JSONDecoder()
            let decodedCursors: [MissedMessageReconciliationCursor]
            if let cursors = try? decoder.decode([MissedMessageReconciliationCursor].self, from: data) {
                decodedCursors = cursors
            } else {
                decodedCursors = [try decoder.decode(MissedMessageReconciliationCursor.self, from: data)]
            }

            let validCursors = compactReconciliationCursors(decodedCursors.filter(isValidReconciliationCursor))
            if validCursors.count != decodedCursors.count {
                saveMissedMessageReconciliationCursors(validCursors)
            }
            return validCursors
        } catch {
            clearMissedMessageReconciliationCursor()
            return []
        }
    }

    private func saveMissedMessageReconciliationCursor(
        query: String,
        nextPageToken: String?,
        startedAt: TimeInterval
    ) {
        guard let nextPageToken, !nextPageToken.isEmpty else {
            clearMissedMessageReconciliationCursor()
            return
        }

        let cursor = MissedMessageReconciliationCursor(
            query: query,
            pageToken: nextPageToken,
            startedAt: startedAt
        )

        saveMissedMessageReconciliationCursors([cursor])
    }

    private func saveMissedMessageReconciliationCursors(_ cursors: [MissedMessageReconciliationCursor]) {
        let validCursors = compactReconciliationCursors(cursors.filter(isValidReconciliationCursor))
        guard !validCursors.isEmpty else {
            clearMissedMessageReconciliationCursor()
            return
        }

        do {
            let data = try JSONEncoder().encode(validCursors)
            UserDefaults.standard.set(data, forKey: SyncConfig.missedMessageReconciliationCursorKey)
        } catch {
            clearMissedMessageReconciliationCursor()
        }
    }

    private func isValidReconciliationCursor(_ cursor: MissedMessageReconciliationCursor) -> Bool {
        let age = Date().timeIntervalSince1970 - cursor.startedAt
        return !cursor.query.isEmpty &&
            !cursor.pageToken.isEmpty &&
            age <= SyncConfig.maxReconciliationWindow
    }

    private func compactReconciliationCursors(
        _ cursors: [MissedMessageReconciliationCursor]
    ) -> [MissedMessageReconciliationCursor] {
        var seen = Set<String>()
        return cursors.filter { cursor in
            seen.insert("\(cursor.query)|\(cursor.pageToken)").inserted
        }
    }

    private func isInvalidReconciliationCursorError(_ error: Error) -> Bool {
        guard let apiError = error as? APIError,
              case .invalidData(let message) = apiError else {
            return false
        }

        let lowercasedMessage = message.lowercased()
        let mentionsPageToken = lowercasedMessage.contains("page token") ||
            lowercasedMessage.contains("pagetoken") ||
            lowercasedMessage.contains("page_token")
        let mentionsCursor = lowercasedMessage.contains("cursor")
        let isInvalidOrExpired = lowercasedMessage.contains("invalid") ||
            lowercasedMessage.contains("expired")

        return isInvalidOrExpired && (mentionsPageToken || mentionsCursor)
    }

    private func clearMissedMessageReconciliationCursor() {
        UserDefaults.standard.removeObject(forKey: SyncConfig.missedMessageReconciliationCursorKey)
    }

    /// Calculates the start time for reconciliation window
    private func calculateReconciliationStartTime(installTimestamp: TimeInterval) -> Date {
        let defaults = UserDefaults.standard
        let lastSuccessfulSync = defaults.double(forKey: SyncConfig.lastSuccessfulSyncTimeKey)

        if lastSuccessfulSync > 0 {
            let timeSinceLastSync = Date().timeIntervalSince1970 - lastSuccessfulSync
            log.debug("Reconciliation window: since last sync (\(Int(timeSinceLastSync / 60)) minutes ago)")
        } else {
            log.debug("Reconciliation window: using fallback (no previous sync time)")
        }

        return SyncTimeCalculator.calculateStartDate(
            config: .reconciliation,
            installTimestamp: installTimestamp
        )
    }

    /// Finds message IDs that don't exist in local database using efficient batch query
    private func findMissingMessages(ids: [String], in context: NSManagedObjectContext) async -> [String] {
        await context.perform {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            request.predicate = MessagePredicates.ids(ids)
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]

            let results: [[String: String]]
            do {
                guard let fetched = try context.fetch(request) as? [[String: String]] else {
                    return ids  // Unexpected result type, assume all missing
                }
                results = fetched
            } catch {
                Log.error("Failed to query local messages for reconciliation", category: .sync, error: error)
                return ids  // If fetch fails, assume all missing
            }

            let existingIds = Set(results.compactMap { $0["id"] })
            return ids.filter { !existingIds.contains($0) }
        }
    }

    // MARK: - Label Reconciliation

    /// Maximum concurrent Gmail API requests during reconciliation
    private static let maxConcurrentGmailRequests = 10

    /// Reconciles label states for recent messages to catch missed label changes
    ///
    /// This is especially important for detecting archive actions that might have been missed.
    /// Compares local labels against Gmail's truth and updates accordingly.
    ///
    /// Optimized with:
    /// - Batch Core Data fetch for local messages
    /// - Parallel Gmail API calls with bounded concurrency
    /// - In-memory mismatch processing
    ///
    /// - Parameters:
    ///   - context: Core Data context
    ///   - labelIds: Pre-fetched label IDs (labels are fetched inside context.perform for thread safety)
    func reconcileLabelStates(
        in context: NSManagedObjectContext,
        labelIds: Set<String>,
        modificationTransaction: ModificationTracker.Transaction?
    ) async {
        _ = await reconcileLabelStatesWithDiagnostics(
            in: context,
            labelIds: labelIds,
            modificationTransaction: modificationTransaction
        )
    }

    func reconcileLabelStatesWithDiagnostics(
        in context: NSManagedObjectContext,
        labelIds: Set<String>,
        modificationTransaction: ModificationTracker.Transaction?
    ) async -> LabelReconciliationResult {
        var diagnostics = SyncReconciliationDiagnostics()

        guard !Task.isCancelled else {
            return LabelReconciliationResult(diagnostics: diagnostics, outcome: .incomplete)
        }

        do {
            // Query recent messages (last 24 hours)
            let oneDayAgo = Date().addingTimeInterval(-86400)
            let epochSeconds = Int(oneDayAgo.timeIntervalSince1970)
            let query = "after:\(epochSeconds) -label:spam -label:drafts -label:trash"

            let (recentMessageIds, _) = try await messageFetcher.listMessages(
                query: query,
                maxResults: 100
            )

            guard !recentMessageIds.isEmpty else {
                log.debug("No recent messages to reconcile labels for")
                return LabelReconciliationResult(diagnostics: diagnostics, outcome: .completed)
            }

            diagnostics.labelMessagesChecked = recentMessageIds.count
            log.debug("Reconciling labels for \(recentMessageIds.count) recent messages")

            // Step 1: Fetch Gmail metadata in parallel with bounded concurrency
            let metadataSummary: MetadataFetchSummary
            do {
                metadataSummary = try await fetchGmailMetadataInParallel(messageIds: recentMessageIds)
            } catch let error as MetadataFetchFailure {
                diagnostics.metadataFetchFailures = error.failureCount
                log.error("Label reconciliation failed", error: error.underlyingError)
                return LabelReconciliationResult(diagnostics: diagnostics, outcome: .incomplete)
            }
            diagnostics.metadataFetchFailures = metadataSummary.failureCount
            diagnostics.skippedChecks += metadataSummary.deletedCount

            // Step 2: Process mismatches (local messages fetched inside context.perform for thread safety)
            let stats = await processReconciliationMismatches(
                gmailMetadata: metadataSummary.metadata,
                messageIds: recentMessageIds,
                context: context,
                modificationTransaction: modificationTransaction
            )
            diagnostics.skippedChecks += stats.skippedChecks
            diagnostics.driftFound = stats.driftFound
            diagnostics.driftRepaired = stats.driftRepaired

            if stats.labelMismatches > 0 {
                log.info("Label reconciliation: found \(stats.labelMismatches) mismatches, updated \(stats.updatedMessages) messages")
            } else {
                log.debug("Label reconciliation: no mismatches (checked \(recentMessageIds.count - stats.notInLocalDB) local messages)")
            }

            let outcome: LabelReconciliationOutcome =
                metadataSummary.failureCount == 0 && !stats.processingFailed && !Task.isCancelled
                ? .completed
                : .incomplete
            return LabelReconciliationResult(diagnostics: diagnostics, outcome: outcome)
        } catch is CancellationError {
            return LabelReconciliationResult(diagnostics: diagnostics, outcome: .incomplete)
        } catch {
            log.error("Label reconciliation failed", error: error)
            return LabelReconciliationResult(diagnostics: diagnostics, outcome: .incomplete)
        }
    }

    /// Gmail message metadata needed for reconciliation
    private struct GmailMetadata {
        let messageId: String
        let hasInbox: Bool
        let isUnread: Bool
    }

    /// Result of fetching Gmail metadata - either successful metadata or an error
    private enum MetadataFetchResult {
        case success(GmailMetadata)
        case deleted(String)  // Message ID that was deleted
        case error(String, Error)  // Message ID and the error
    }

    private struct MetadataFetchSummary {
        let metadata: [String: GmailMetadata]
        let failureCount: Int
        let deletedCount: Int
    }

    private struct MetadataFetchFailure: Error {
        let failureCount: Int
        let underlyingError: Error
    }

    /// Fetches Gmail metadata in parallel with bounded concurrency
    /// Returns metadata for messages that still exist, skips deleted messages, and throws on transient errors
    private func fetchGmailMetadataInParallel(messageIds: [String]) async throws -> MetadataFetchSummary {
        // Use chunks to limit concurrent requests
        let chunks = messageIds.chunked(into: Self.maxConcurrentGmailRequests)
        var allMetadata: [String: GmailMetadata] = [:]
        var transientErrors: [(String, Error)] = []
        var deletedCount = 0
        let messageFetcher = self.messageFetcher

        for chunk in chunks {
            let results = await withTaskGroup(of: MetadataFetchResult.self) { group -> [MetadataFetchResult] in
                for messageId in chunk {
                    group.addTask {
                        do {
                            let gmailMessage = try await messageFetcher.getMessageMetadata(id: messageId)
                            let labelIds = Set(gmailMessage.labelIds ?? [])
                            return .success(GmailMetadata(
                                messageId: messageId,
                                hasInbox: labelIds.contains("INBOX"),
                                isUnread: labelIds.contains("UNREAD")
                            ))
                        } catch let error as APIError {
                            // Only treat 404 (notFound) as "deleted"
                            if case .notFound = error {
                                return .deleted(messageId)
                            }
                            // All other API errors (rate limit, auth, server errors) are transient
                            return .error(messageId, error)
                        } catch {
                            // Network errors and other failures are transient
                            return .error(messageId, error)
                        }
                    }
                }

                var results: [MetadataFetchResult] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            for result in results {
                switch result {
                case .success(let metadata):
                    allMetadata[metadata.messageId] = metadata
                case .deleted(let messageId):
                    deletedCount += 1
                    log.debug("Message \(messageId) was deleted from Gmail, skipping reconciliation")
                case .error(let messageId, let error):
                    transientErrors.append((messageId, error))
                }
            }
        }

        // If we had transient errors but got SOME metadata, log warning and continue
        // If ALL requests failed, that's likely a systemic issue - throw to caller
        if !transientErrors.isEmpty {
            if allMetadata.isEmpty && !messageIds.isEmpty {
                // All requests failed - likely auth/network/rate limit issue
                let (_, firstError) = transientErrors[0]
                log.error("All metadata fetches failed (\(transientErrors.count) errors), aborting reconciliation", error: firstError)
                throw MetadataFetchFailure(
                    failureCount: transientErrors.count,
                    underlyingError: firstError
                )
            } else {
                // Some succeeded, some failed - log and continue with what we have
                log.warning("Metadata fetch had \(transientErrors.count) transient errors, continuing with \(allMetadata.count) successful fetches")
            }
        }

        return MetadataFetchSummary(
            metadata: allMetadata,
            failureCount: transientErrors.count,
            deletedCount: deletedCount
        )
    }

    /// Result of reconciling a single message
    private struct MessageReconcileResult {
        var hadMismatch = false
        var wasUpdated = false
        var notInLocalDB = false
    }

    /// Processes reconciliation mismatches using pre-fetched data
    /// Returns stats and conversation ObjectIDs that were modified
    private func processReconciliationMismatches(
        gmailMetadata: [String: GmailMetadata],
        messageIds: [String],
        context: NSManagedObjectContext,
        modificationTransaction: ModificationTracker.Transaction?
    ) async -> ReconciliationStats {
        // Capture only Sendable data for the closure
        let gmailData = gmailMetadata

        let (stats, conversationObjectIDs): (ReconciliationStats, [NSManagedObjectID]) = await context.perform {
            var stats = ReconciliationStats()
            var modifiedConversationIDs: [NSManagedObjectID] = []

            // Fetch local messages inside context.perform for thread safety
            let messageRequest = Message.fetchRequest()
            messageRequest.predicate = NSPredicate(format: "id IN %@", messageIds)
            messageRequest.relationshipKeyPathsForPrefetching = ["labels", "conversation"]
            messageRequest.fetchBatchSize = 50

            let localMessages: [Message]
            do {
                localMessages = try context.fetch(messageRequest)
            } catch {
                Log.error("Failed to fetch local messages for label reconciliation", category: .sync, error: error)
                stats.processingFailed = true
                return (stats, modifiedConversationIDs)
            }

            let groupedMessages = Dictionary(grouping: localMessages, by: { $0.id })
            var localMessageDict: [String: Message] = [:]
            localMessageDict.reserveCapacity(groupedMessages.count)

            for (id, messages) in groupedMessages {
                if messages.count > 1 {
                    self.log.error("Duplicate Message id \(id) in local DB during reconciliation; keeping most recent")
                }

                let preferred = messages.max { lhs, rhs in
                    let lhsDate = lhs.localModifiedAt ?? lhs.internalDate
                    let rhsDate = rhs.localModifiedAt ?? rhs.internalDate
                    return lhsDate < rhsDate
                } ?? messages[0]

                localMessageDict[id] = preferred
            }

            // Pre-fetch INBOX label once for all messages that might need it
            let labelRequest = Label.fetchRequest()
            labelRequest.predicate = NSPredicate(format: "id == %@", "INBOX")
            labelRequest.fetchLimit = 1
            let inboxLabel: Label?
            do {
                inboxLabel = try context.fetch(labelRequest).first
            } catch {
                Log.error("Failed to fetch INBOX label for reconciliation", category: .coreData, error: error)
                stats.processingFailed = true
                inboxLabel = nil
            }

            for (messageId, gmail) in gmailData {
                guard let localMessage = localMessageDict[messageId] else {
                    stats.notInLocalDB += 1
                    stats.skippedChecks += 1
                    continue
                }

                // Skip if message has pending local changes that have not yet been synced.
                if HistoryProcessor.hasPendingLocalModification(message: localMessage) {
                    stats.skippedChecks += 1
                    continue
                }

                let localLabels = localMessage.labels ?? []
                let localHasInbox = localLabels.contains { $0.id == "INBOX" }
                var messageHadDrift = false
                var messageWasRepaired = false
                var wasModified = false

                // Check INBOX label discrepancy
                if gmail.hasInbox != localHasInbox {
                    // Don't re-add INBOX if locally marked as SPAM - user intent takes precedence
                    let localHasSpam = localLabels.contains { $0.id == "SPAM" }
                    if gmail.hasInbox && localHasSpam {
                        stats.skippedChecks += 1
                        continue
                    }

                    stats.labelMismatches += 1
                    messageHadDrift = true

                    if gmail.hasInbox {
                        if let inboxLabel = inboxLabel {
                            localMessage.addToLabels(inboxLabel)
                            messageWasRepaired = true
                        }
                    } else {
                        if let existingInbox = localLabels.first(where: { $0.id == "INBOX" }) {
                            localMessage.removeFromLabels(existingInbox)
                            messageWasRepaired = true
                        }
                    }

                    wasModified = true
                    stats.updatedMessages += 1
                }

                // Check UNREAD status
                if localMessage.isUnread != gmail.isUnread {
                    messageHadDrift = true
                    localMessage.isUnread = gmail.isUnread
                    messageWasRepaired = true
                    wasModified = true
                }

                if messageHadDrift {
                    stats.driftFound += 1
                }
                if messageWasRepaired {
                    stats.driftRepaired += 1
                }

                if wasModified, let conversationID = localMessage.conversation?.objectID {
                    modifiedConversationIDs.append(conversationID)
                }
            }

            return (stats, modifiedConversationIDs)
        }

        // Track modified conversations using ObjectIDs (actor-isolated)
        for objectID in conversationObjectIDs {
            await ModificationTracker.shared.trackModifiedConversation(
                objectID,
                in: modificationTransaction
            )
        }

        return stats
    }
}

// MARK: - Supporting Types

private struct ReconciliationStats {
    var labelMismatches = 0
    var updatedMessages = 0
    var notInLocalDB = 0
    var skippedChecks = 0
    var driftFound = 0
    var driftRepaired = 0
    var processingFailed = false
}
