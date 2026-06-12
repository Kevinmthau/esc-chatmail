import Foundation
import CoreData

/// Tracks sync failures and determines when to advance historyId despite failures
///
/// This prevents sync from getting permanently stuck on unfetchable messages
/// by advancing historyId after a configurable number of consecutive failures.
/// Abandoned message IDs are persisted to Core Data for potential retry.
actor SyncFailureTracker {
    static let shared = SyncFailureTracker()

    private let defaults: UserDefaults
    private let coreDataStack: CoreDataStack
    private let log = LogCategory.sync.logger

    init(defaults: UserDefaults = .standard, coreDataStack: CoreDataStack = .shared) {
        self.defaults = defaults
        self.coreDataStack = coreDataStack
    }

    // MARK: - Public API

    /// Records a successful sync and resets failure tracking
    func recordSuccess() {
        defaults.set(0, forKey: SyncConfig.consecutiveFailuresKey)
        defaults.removeObject(forKey: SyncConfig.persistentFailedIdsKey)
        defaults.set(Date().timeIntervalSince1970, forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        log.debug("Sync success - reset failure tracking")
    }

    /// Records failed message IDs and increments failure counter
    /// - Parameter failedIds: Message IDs that failed to fetch
    func recordFailure(failedIds: [String]) {
        guard !failedIds.isEmpty else { return }

        // Increment consecutive failure count
        let consecutiveFailures = defaults.integer(forKey: SyncConfig.consecutiveFailuresKey) + 1
        defaults.set(consecutiveFailures, forKey: SyncConfig.consecutiveFailuresKey)

        // Track persistent failed IDs
        var persistentIds = defaults.stringArray(forKey: SyncConfig.persistentFailedIdsKey) ?? []
        let existingSet = Set(persistentIds)
        let newIds = failedIds.filter { !existingSet.contains($0) }
        persistentIds.append(contentsOf: newIds)

        // Limit size to prevent unbounded growth
        let maxSize = SyncConfig.maxFailedMessagesBeforeAdvance * 2
        if persistentIds.count > maxSize {
            persistentIds = Array(persistentIds.suffix(SyncConfig.maxFailedMessagesBeforeAdvance))
        }

        defaults.set(persistentIds, forKey: SyncConfig.persistentFailedIdsKey)

        log.warning("Consecutive failures: \(consecutiveFailures)/\(SyncConfig.maxConsecutiveSyncFailures), tracking \(persistentIds.count) failed IDs")
    }

    /// Determines whether historyId should be advanced despite failures
    ///
    /// Returns true if:
    /// - There were no failures (normal success case)
    /// - Maximum consecutive failures reached (to prevent deadlock)
    ///
    /// When maximum failures are reached, abandoned message IDs are persisted to Core Data
    /// and a notification is posted so the UI can inform the user.
    ///
    /// - Parameters:
    ///   - hadFailures: Whether any messages failed to fetch
    ///   - latestHistoryId: The new historyId to potentially advance to
    /// - Returns: true if historyId should be advanced
    func shouldAdvanceHistoryId(hadFailures: Bool, latestHistoryId: String) async -> Bool {
        if !hadFailures {
            recordSuccess()
            return true
        }

        let consecutiveFailures = defaults.integer(forKey: SyncConfig.consecutiveFailuresKey)

        if consecutiveFailures >= SyncConfig.maxConsecutiveSyncFailures {
            log.warning("Maximum consecutive failures (\(consecutiveFailures)) reached - advancing historyId to prevent deadlock")

            // Persist abandoned messages to Core Data and notify UI
            if let persistentFailedIds = defaults.stringArray(forKey: SyncConfig.persistentFailedIdsKey), !persistentFailedIds.isEmpty {
                log.warning("Abandoning \(persistentFailedIds.count) unfetchable messages: \(persistentFailedIds.prefix(10))...")
                await persistAbandonedMessages(messageIds: persistentFailedIds, reason: "Max sync failures reached")
            }

            // Reset tracking since we're moving forward
            recordSuccess()
            return true
        }

        log.info("Not advancing historyId - \(consecutiveFailures) consecutive failures (max: \(SyncConfig.maxConsecutiveSyncFailures))")
        return false
    }

    /// Persists abandoned message IDs to Core Data for later retry
    private func persistAbandonedMessages(messageIds: [String], reason: String) async {
        let context = coreDataStack.newBackgroundContext()

        await context.perform {
            let abandonedAt = Date()

            // Batch fetch all existing abandoned messages in a single query (eliminates N+1)
            let existingRequest = NSFetchRequest<AbandonedSyncMessage>(entityName: "AbandonedSyncMessage")
            existingRequest.predicate = NSPredicate(format: "gmailMessageId IN %@", messageIds)
            let existingMessages = (try? context.fetch(existingRequest)) ?? []

            // Create dictionary for O(1) lookup
            var existingByGmailId: [String: AbandonedSyncMessage] = [:]
            for message in existingMessages {
                if let gmailId = message.value(forKey: "gmailMessageId") as? String {
                    existingByGmailId[gmailId] = message
                }
            }

            // Update or create records. retryCount is owned by the abandoned-message
            // drain (recordAbandonedRetryOutcome) and counts drain attempts only;
            // re-abandonment must not consume the drain's retry budget.
            for messageId in messageIds {
                if let existing = existingByGmailId[messageId] {
                    // Update existing record
                    existing.setValue(abandonedAt, forKey: "abandonedAt")
                    existing.setValue(reason, forKey: "reason")
                } else {
                    // Create new record
                    let abandoned = AbandonedSyncMessage(context: context)
                    abandoned.setValue(UUID(), forKey: "id")
                    abandoned.setValue(messageId, forKey: "gmailMessageId")
                    abandoned.setValue(abandonedAt, forKey: "abandonedAt")
                    abandoned.setValue(Int16(0), forKey: "retryCount")
                    abandoned.setValue(reason, forKey: "reason")
                }
            }

            do {
                try context.save()
                Log.info("Persisted \(messageIds.count) abandoned message IDs to Core Data", category: .sync)
            } catch {
                Log.error("Failed to persist abandoned messages", category: .sync, error: error)
            }
        }

        // New records start with retryCount 0, so the drain has work again.
        mayHaveRetryableAbandonedMessages = true

        // Notify UI about abandoned messages
        await MainActor.run {
            NotificationCenter.default.post(
                name: .syncMessagesAbandoned,
                object: nil,
                userInfo: ["count": messageIds.count]
            )
        }
    }

    // MARK: - Query Methods

    /// Returns the timestamp of the last successful sync
    var lastSuccessfulSyncTime: Date? {
        let timestamp = defaults.double(forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    /// Returns the number of consecutive sync failures
    var consecutiveFailureCount: Int {
        defaults.integer(forKey: SyncConfig.consecutiveFailuresKey)
    }

    /// Returns the IDs of persistently failed messages
    var persistentFailedIds: [String] {
        defaults.stringArray(forKey: SyncConfig.persistentFailedIdsKey) ?? []
    }

    /// Clears all failure tracking state
    func reset() {
        defaults.set(0, forKey: SyncConfig.consecutiveFailuresKey)
        defaults.removeObject(forKey: SyncConfig.persistentFailedIdsKey)
        log.debug("Failure tracking reset")
    }

    // MARK: - Abandoned Sync Messages

    /// Whether the store may contain retryable abandoned records. `nil` means unknown
    /// (check the store); `false` lets the per-sync drain skip the Core Data fetch in
    /// the common steady state of an empty table. Reset to `nil` by every mutator.
    private var mayHaveRetryableAbandonedMessages: Bool?

    /// Returns abandoned message IDs that are still worth retrying, oldest first.
    /// IDs whose retryCount has reached `SyncConfig.maxAbandonedMessageRetries` are
    /// excluded permanently.
    func fetchRetryableAbandonedMessageIds(limit: Int = SyncConfig.maxAbandonedMessagesPerSync) async -> [String] {
        if mayHaveRetryableAbandonedMessages == false {
            return []
        }

        await resetLegacyRetryCountsIfNeeded()

        let context = coreDataStack.newBackgroundContext()
        let ids: [String]? = await context.perform {
            let request = NSFetchRequest<AbandonedSyncMessage>(entityName: "AbandonedSyncMessage")
            request.predicate = NSPredicate(format: "retryCount < %d", SyncConfig.maxAbandonedMessageRetries)
            request.sortDescriptors = [NSSortDescriptor(key: "abandonedAt", ascending: true)]
            request.fetchLimit = limit

            do {
                let messages = try context.fetch(request)
                return messages.compactMap { $0.value(forKey: "gmailMessageId") as? String }
            } catch {
                Log.error("Failed to fetch retryable abandoned sync messages", category: .sync, error: error)
                return nil
            }
        }

        // Only cache on a successful fetch — an error must not latch "empty".
        if let ids {
            mayHaveRetryableAbandonedMessages = !ids.isEmpty
        }
        return ids ?? []
    }

    /// One-time reset of retryCount on records written before the retry drain
    /// existed: the old code incremented retryCount on every re-abandonment, so a
    /// legacy record could sit at or above the drain's cap without a single drain
    /// attempt having run — permanently hidden by the `retryCount <` predicate.
    private func resetLegacyRetryCountsIfNeeded() async {
        guard !defaults.bool(forKey: SyncConfig.abandonedRetryCountResetKey) else { return }

        let context = coreDataStack.newBackgroundContext()
        let didReset: Bool = await context.perform {
            let request = NSFetchRequest<AbandonedSyncMessage>(entityName: "AbandonedSyncMessage")
            request.predicate = NSPredicate(format: "retryCount > 0")

            do {
                let records = try context.fetch(request)
                for record in records {
                    record.setValue(Int16(0), forKey: "retryCount")
                }
                if context.hasChanges {
                    try context.save()
                    Log.info("Reset legacy retryCount on \(records.count) abandoned messages", category: .sync)
                }
                return true
            } catch {
                Log.error("Failed to reset legacy abandoned retry counts", category: .sync, error: error)
                return false
            }
        }

        if didReset {
            defaults.set(true, forKey: SyncConfig.abandonedRetryCountResetKey)
        }
    }

    /// Applies the outcome of an abandoned-message retry pass: recovered and
    /// server-side-deleted messages are removed from tracking; transient failures
    /// have their retryCount incremented. Records whose retryCount reaches
    /// `SyncConfig.maxAbandonedMessageRetries` are deleted — they would never be
    /// offered again, and keeping them would grow the table without bound.
    func recordAbandonedRetryOutcome(recoveredIds: [String], goneIds: [String], failedIds: [String]) async {
        let resolvedIds = recoveredIds + goneIds
        guard !resolvedIds.isEmpty || !failedIds.isEmpty else { return }

        if !recoveredIds.isEmpty {
            log.info("Recovered \(recoveredIds.count) previously abandoned messages")
        }
        if !goneIds.isEmpty {
            log.info("Dropping \(goneIds.count) abandoned messages deleted server-side")
        }

        mayHaveRetryableAbandonedMessages = nil

        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            let request = NSFetchRequest<AbandonedSyncMessage>(entityName: "AbandonedSyncMessage")
            request.predicate = NSPredicate(format: "gmailMessageId IN %@", resolvedIds + failedIds)

            do {
                let resolvedSet = Set(resolvedIds)
                for record in try context.fetch(request) {
                    guard let gmailId = record.value(forKey: "gmailMessageId") as? String else { continue }
                    if resolvedSet.contains(gmailId) {
                        context.delete(record)
                    } else {
                        let retryCount = (record.value(forKey: "retryCount") as? Int16 ?? 0) + 1
                        if retryCount >= SyncConfig.maxAbandonedMessageRetries {
                            Log.warning("Giving up on abandoned message \(gmailId) after \(retryCount) retries", category: .sync)
                            context.delete(record)
                        } else {
                            record.setValue(retryCount, forKey: "retryCount")
                        }
                    }
                }
                if context.hasChanges {
                    try context.save()
                }
            } catch {
                Log.error("Failed to record abandoned retry outcome", category: .sync, error: error)
            }
        }
    }
}
