import Foundation
import CoreData

/// Manages persistent state for background sync (historyId, retry logic)
final class BackgroundSyncStateManager {
    private let coreDataStack: CoreDataStack

    private var currentRetryCount = 0
    private var currentBackoff: TimeInterval
    private let maxRetries: Int
    private let initialBackoffSeconds: TimeInterval
    private let maxBackoffSeconds: TimeInterval

    init(
        coreDataStack: CoreDataStack = .shared,
        maxRetries: Int = 3,
        initialBackoffSeconds: TimeInterval = 30,
        maxBackoffSeconds: TimeInterval = 3600
    ) {
        self.coreDataStack = coreDataStack
        self.maxRetries = maxRetries
        self.initialBackoffSeconds = initialBackoffSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
        self.currentBackoff = initialBackoffSeconds
    }

    /// Retrieves the stored history ID from Core Data
    func getStoredHistoryId() -> String? {
        var historyId: String? = nil
        let context = coreDataStack.newBackgroundContext()
        context.performAndWait {
            let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
            fetchRequest.fetchLimit = 1

            do {
                let accounts = try context.fetch(fetchRequest)
                historyId = accounts.first?.historyId
            } catch {
                Log.error("Failed to fetch historyId", category: .background, error: error)
            }
        }
        return historyId
    }

    /// Stores the history ID in Core Data
    func storeHistoryId(_ historyId: String) {
        Task {
            do {
                try await coreDataStack.performBackgroundTask { [weak self] context in
                    guard let self = self else { return }
                    let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
                    fetchRequest.fetchLimit = 1

                    let accounts = try context.fetch(fetchRequest)
                    if let account = accounts.first {
                        account.historyId = historyId
                        try self.coreDataStack.save(context: context)
                    }
                }
            } catch {
                Log.error("Failed to store historyId", category: .background, error: error)
            }
        }
    }

    /// Increments retry count and returns whether we should retry
    /// Returns the backoff interval if we should retry, nil if we've exceeded max retries
    func incrementRetryAndGetBackoff() -> TimeInterval? {
        currentRetryCount += 1

        if currentRetryCount >= maxRetries {
            currentRetryCount = 0
            currentBackoff = initialBackoffSeconds
            return nil
        } else {
            currentBackoff = min(currentBackoff * 2, maxBackoffSeconds)
            return currentBackoff
        }
    }

    /// Resets retry count and backoff to initial values
    func resetRetryCount() {
        currentRetryCount = 0
        currentBackoff = initialBackoffSeconds
    }
}
