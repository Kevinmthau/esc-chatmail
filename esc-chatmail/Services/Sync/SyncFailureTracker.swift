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

            // Update or create records
            for messageId in messageIds {
                if let existing = existingByGmailId[messageId] {
                    // Update existing record
                    existing.setValue(abandonedAt, forKey: "abandonedAt")
                    let currentRetryCount = existing.value(forKey: "retryCount") as? Int16 ?? 0
                    existing.setValue(currentRetryCount + 1, forKey: "retryCount")
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

    /// Returns the count of abandoned sync messages
    func abandonedSyncMessageCount() async -> Int {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<NSNumber>(entityName: "AbandonedSyncMessage")
            request.resultType = .countResultType

            do {
                return try context.fetch(request).first?.intValue ?? 0
            } catch {
                Log.error("Failed to count abandoned sync messages", category: .sync, error: error)
                return 0
            }
        }
    }

    /// Returns all abandoned sync message IDs
    func fetchAbandonedSyncMessageIds() async -> [String] {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<AbandonedSyncMessage>(entityName: "AbandonedSyncMessage")
            request.sortDescriptors = [NSSortDescriptor(key: "abandonedAt", ascending: false)]

            do {
                let messages = try context.fetch(request)
                return messages.compactMap { $0.value(forKey: "gmailMessageId") as? String }
            } catch {
                Log.error("Failed to fetch abandoned sync messages", category: .sync, error: error)
                return []
            }
        }
    }

    /// Removes an abandoned sync message after successful retry
    func removeAbandonedSyncMessage(gmailMessageId: String) async {
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            let request = NSFetchRequest<AbandonedSyncMessage>(entityName: "AbandonedSyncMessage")
            request.predicate = NSPredicate(format: "gmailMessageId == %@", gmailMessageId)

            do {
                let messages = try context.fetch(request)
                for message in messages {
                    context.delete(message)
                }
                try context.save()
            } catch {
                Log.error("Failed to remove abandoned sync message", category: .sync, error: error)
            }
        }
    }

    /// Clears all abandoned sync messages
    func clearAllAbandonedSyncMessages() async {
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            let request = NSFetchRequest<AbandonedSyncMessage>(entityName: "AbandonedSyncMessage")

            do {
                let messages = try context.fetch(request)
                for message in messages {
                    context.delete(message)
                }
                try context.save()
                Log.info("Cleared \(messages.count) abandoned sync messages", category: .sync)
            } catch {
                Log.error("Failed to clear abandoned sync messages", category: .sync, error: error)
            }
        }
    }
}
