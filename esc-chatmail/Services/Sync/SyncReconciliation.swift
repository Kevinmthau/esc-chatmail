import Foundation
import CoreData

/// Handles reconciliation between Gmail and local state
///
/// Responsibilities:
/// - Detect and fetch missed messages
/// - Reconcile label states (especially INBOX for archive detection)
/// - Verify local state matches Gmail truth
final class SyncReconciliation: Sendable {

    private let messageFetcher: MessageFetcher
    private let historyProcessor: HistoryProcessor
    private let failureTracker: SyncFailureTracker
    private let log = LogCategory.sync.logger

    init(
        messageFetcher: MessageFetcher,
        historyProcessor: HistoryProcessor,
        failureTracker: SyncFailureTracker = .shared
    ) {
        self.messageFetcher = messageFetcher
        self.historyProcessor = historyProcessor
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
        do {
            let reconciliationStartTime = calculateReconciliationStartTime(installTimestamp: installTimestamp)
            let epochSeconds = Int(reconciliationStartTime.timeIntervalSince1970)

            let query = "after:\(epochSeconds) -label:spam -label:drafts"

            // Scale max results based on time since last sync
            let timeSinceStart = Date().timeIntervalSince(reconciliationStartTime)
            let maxResults = min(200, max(50, Int(timeSinceStart / 3600) * 20))

            let (recentMessageIds, _) = try await messageFetcher.listMessages(
                query: query,
                maxResults: maxResults
            )

            guard !recentMessageIds.isEmpty else {
                log.debug("No recent messages to check for reconciliation")
                return []
            }

            log.debug("Checking \(recentMessageIds.count) recent Gmail messages against local DB")

            let missingIds = await findMissingMessages(ids: recentMessageIds, in: context)

            if !missingIds.isEmpty {
                log.info("Found \(missingIds.count) messages in Gmail but not locally")
            }

            return missingIds
        } catch {
            log.error("Reconciliation check failed", error: error)
            return []
        }
    }

    /// Calculates the start time for reconciliation window
    private func calculateReconciliationStartTime(installTimestamp: TimeInterval) -> Date {
        let defaults = UserDefaults.standard
        let lastSuccessfulSync = defaults.double(forKey: SyncConfig.lastSuccessfulSyncTimeKey)

        let reconciliationStartTime: Date
        if lastSuccessfulSync > 0 {
            // Use last successful sync time with 5-minute buffer
            reconciliationStartTime = Date(timeIntervalSince1970: lastSuccessfulSync - 300)
            let timeSinceLastSync = Date().timeIntervalSince1970 - lastSuccessfulSync
            log.debug("Reconciliation window: since last sync (\(Int(timeSinceLastSync / 60)) minutes ago)")
        } else {
            // Fallback to 1 hour
            reconciliationStartTime = Date().addingTimeInterval(-3600)
            log.debug("Reconciliation window: last 1 hour (no previous sync time)")
        }

        // Cap to 24 hours maximum
        let maxReconciliationTime = Date().addingTimeInterval(-86400)

        // Never reconcile messages from before install
        let installCutoff = installTimestamp > 0
            ? Date(timeIntervalSince1970: installTimestamp - 300)
            : Date.distantPast

        return max(reconciliationStartTime, maxReconciliationTime, installCutoff)
    }

    /// Finds message IDs that don't exist in local database using efficient batch query
    private func findMissingMessages(ids: [String], in context: NSManagedObjectContext) async -> [String] {
        await context.perform {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            request.predicate = MessagePredicates.ids(ids)
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]

            guard let results = try? context.fetch(request) as? [[String: String]] else {
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
        labelIds: Set<String>
    ) async {
        do {
            // Query recent messages (last 24 hours)
            let oneDayAgo = Date().addingTimeInterval(-86400)
            let epochSeconds = Int(oneDayAgo.timeIntervalSince1970)
            let query = "after:\(epochSeconds) -label:spam -label:drafts"

            let (recentMessageIds, _) = try await messageFetcher.listMessages(
                query: query,
                maxResults: 100
            )

            guard !recentMessageIds.isEmpty else {
                log.debug("No recent messages to reconcile labels for")
                return
            }

            log.debug("Reconciling labels for \(recentMessageIds.count) recent messages")

            // Step 1: Fetch Gmail metadata in parallel with bounded concurrency
            let gmailMetadata = await fetchGmailMetadataInParallel(messageIds: recentMessageIds)

            // Step 2: Process mismatches (local messages fetched inside context.perform for thread safety)
            let stats = await processReconciliationMismatches(
                gmailMetadata: gmailMetadata,
                messageIds: recentMessageIds,
                context: context
            )

            if stats.labelMismatches > 0 {
                log.info("Label reconciliation: found \(stats.labelMismatches) mismatches, updated \(stats.updatedMessages) messages")
            } else {
                log.debug("Label reconciliation: no mismatches (checked \(recentMessageIds.count - stats.notInLocalDB) local messages)")
            }
        } catch {
            log.error("Label reconciliation failed", error: error)
        }
    }

    /// Gmail message metadata needed for reconciliation
    private struct GmailMetadata {
        let messageId: String
        let hasInbox: Bool
        let isUnread: Bool
    }

    /// Fetches Gmail metadata in parallel with bounded concurrency
    private func fetchGmailMetadataInParallel(messageIds: [String]) async -> [String: GmailMetadata] {
        // Use chunks to limit concurrent requests
        let chunks = messageIds.chunked(into: Self.maxConcurrentGmailRequests)
        var allMetadata: [String: GmailMetadata] = [:]

        for chunk in chunks {
            await withTaskGroup(of: GmailMetadata?.self) { group in
                for messageId in chunk {
                    group.addTask {
                        do {
                            let gmailMessage = try await GmailAPIClient.shared.getMessage(id: messageId, format: "metadata")
                            let labelIds = Set(gmailMessage.labelIds ?? [])
                            return GmailMetadata(
                                messageId: messageId,
                                hasInbox: labelIds.contains("INBOX"),
                                isUnread: labelIds.contains("UNREAD")
                            )
                        } catch {
                            // Skip messages that fail to fetch (might be deleted)
                            return nil
                        }
                    }
                }

                for await metadata in group {
                    if let metadata = metadata {
                        allMetadata[metadata.messageId] = metadata
                    }
                }
            }
        }

        return allMetadata
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
        context: NSManagedObjectContext
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

            guard let localMessages = try? context.fetch(messageRequest) else {
                return (stats, modifiedConversationIDs)
            }

            let localMessageDict = Dictionary(uniqueKeysWithValues: localMessages.map { ($0.id, $0) })

            // Pre-fetch INBOX label once for all messages that might need it
            let labelRequest = Label.fetchRequest()
            labelRequest.predicate = NSPredicate(format: "id == %@", "INBOX")
            labelRequest.fetchLimit = 1
            let inboxLabel = try? context.fetch(labelRequest).first

            for (messageId, gmail) in gmailData {
                guard let localMessage = localMessageDict[messageId] else {
                    stats.notInLocalDB += 1
                    continue
                }

                // Skip if message has pending local changes (modified in last 30 minutes)
                if let localModifiedAt = localMessage.localModifiedAtValue,
                   localModifiedAt > Date().addingTimeInterval(-1800) {
                    continue
                }

                let localLabels = localMessage.labels ?? []
                let localHasInbox = localLabels.contains { $0.id == "INBOX" }
                var wasModified = false

                // Check INBOX label discrepancy
                if gmail.hasInbox != localHasInbox {
                    stats.labelMismatches += 1

                    if gmail.hasInbox {
                        if let inboxLabel = inboxLabel {
                            localMessage.addToLabels(inboxLabel)
                        }
                    } else {
                        if let existingInbox = localLabels.first(where: { $0.id == "INBOX" }) {
                            localMessage.removeFromLabels(existingInbox)
                        }
                    }

                    wasModified = true
                    stats.updatedMessages += 1
                }

                // Check UNREAD status
                if localMessage.isUnread != gmail.isUnread {
                    localMessage.isUnread = gmail.isUnread
                    wasModified = true
                }

                if wasModified, let conversationID = localMessage.conversation?.objectID {
                    modifiedConversationIDs.append(conversationID)
                }
            }

            return (stats, modifiedConversationIDs)
        }

        // Track modified conversations using ObjectIDs (actor-isolated)
        for objectID in conversationObjectIDs {
            await historyProcessor.trackModifiedConversation(objectID)
        }

        return stats
    }
}

// MARK: - Supporting Types

private struct ReconciliationStats {
    var labelMismatches = 0
    var updatedMessages = 0
    var notInLocalDB = 0
}
