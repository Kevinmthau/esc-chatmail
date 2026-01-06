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

    /// Reconciles label states for recent messages to catch missed label changes
    ///
    /// This is especially important for detecting archive actions that might have been missed.
    /// Compares local labels against Gmail's truth and updates accordingly.
    ///
    /// - Parameters:
    ///   - context: Core Data context
    ///   - labelIds: Pre-fetched label IDs (labels are fetched inside context.perform for thread safety)
    func reconcileLabelStates(
        in context: NSManagedObjectContext,
        labelIds: Set<String>
    ) async {
        do {
            // Query recent messages (last 2 hours)
            let twoHoursAgo = Date().addingTimeInterval(-7200)
            let epochSeconds = Int(twoHoursAgo.timeIntervalSince1970)
            let query = "after:\(epochSeconds) -label:spam -label:drafts"

            let (recentMessageIds, _) = try await messageFetcher.listMessages(
                query: query,
                maxResults: 30
            )

            guard !recentMessageIds.isEmpty else {
                log.debug("No recent messages to reconcile labels for")
                return
            }

            log.debug("Reconciling labels for \(recentMessageIds.count) recent messages")

            var stats = ReconciliationStats()

            for messageId in recentMessageIds {
                let result = await reconcileMessageLabels(
                    messageId: messageId,
                    context: context,
                    labelIds: labelIds
                )
                if result.hadMismatch { stats.labelMismatches += 1 }
                if result.wasUpdated { stats.updatedMessages += 1 }
                if result.notInLocalDB { stats.notInLocalDB += 1 }
            }

            if stats.labelMismatches > 0 {
                log.info("Label reconciliation: found \(stats.labelMismatches) mismatches, updated \(stats.updatedMessages) messages")
            } else {
                log.debug("Label reconciliation: no mismatches (checked \(recentMessageIds.count - stats.notInLocalDB) local messages)")
            }
        } catch {
            log.error("Label reconciliation failed", error: error)
        }
    }

    /// Result of reconciling a single message
    private struct MessageReconcileResult {
        var hadMismatch = false
        var wasUpdated = false
        var notInLocalDB = false
    }

    /// Reconciles labels for a single message
    private func reconcileMessageLabels(
        messageId: String,
        context: NSManagedObjectContext,
        labelIds: Set<String>
    ) async -> MessageReconcileResult {
        do {
            // Fetch message from Gmail
            let gmailMessage = try await GmailAPIClient.shared.getMessage(id: messageId, format: "metadata")
            let gmailLabelIds = Set(gmailMessage.labelIds ?? [])
            let gmailHasInbox = gmailLabelIds.contains("INBOX")
            let gmailIsUnread = gmailLabelIds.contains("UNREAD")

            let (result, conversationToTrack): (MessageReconcileResult, Conversation?) = await context.perform {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId)
                request.fetchLimit = 1

                guard let localMessage = try? context.fetch(request).first else {
                    return (MessageReconcileResult(notInLocalDB: true), nil)
                }

                // Skip if message has pending local changes (modified in last 5 minutes)
                if let localModifiedAt = localMessage.localModifiedAtValue,
                   localModifiedAt > Date().addingTimeInterval(-300) {
                    return (MessageReconcileResult(), nil)
                }

                var result = MessageReconcileResult()
                var conversationToTrack: Conversation? = nil
                let localLabels = localMessage.labels ?? []
                let localHasInbox = localLabels.contains { $0.id == "INBOX" }

                // Check INBOX label discrepancy (most important for archive detection)
                if gmailHasInbox != localHasInbox {
                    result.hadMismatch = true

                    if gmailHasInbox {
                        // Fetch INBOX label inside context.perform for thread safety
                        let labelRequest = Label.fetchRequest()
                        labelRequest.predicate = NSPredicate(format: "id == %@", "INBOX")
                        labelRequest.fetchLimit = 1
                        if let inboxLabel = try? context.fetch(labelRequest).first {
                            localMessage.addToLabels(inboxLabel)
                        }
                    } else {
                        if let inboxLabel = localLabels.first(where: { $0.id == "INBOX" }) {
                            localMessage.removeFromLabels(inboxLabel)
                        }
                    }

                    conversationToTrack = localMessage.conversation
                    result.wasUpdated = true
                }

                // Check UNREAD status
                if localMessage.isUnread != gmailIsUnread {
                    localMessage.isUnread = gmailIsUnread
                    if conversationToTrack == nil {
                        conversationToTrack = localMessage.conversation
                    }
                }

                return (result, conversationToTrack)
            }

            // Track modified conversation outside the closure (actor-isolated)
            if let conversation = conversationToTrack {
                await historyProcessor.trackModifiedConversationForReconciliation(conversation)
            }

            return result
        } catch {
            // Skip messages that fail to fetch (might be deleted)
            return MessageReconcileResult()
        }
    }
}

// MARK: - Supporting Types

private struct ReconciliationStats {
    var labelMismatches = 0
    var updatedMessages = 0
    var notInLocalDB = 0
}
