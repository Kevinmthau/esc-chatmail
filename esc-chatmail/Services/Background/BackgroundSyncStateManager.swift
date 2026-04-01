import Foundation
import CoreData
import os

enum BackgroundSyncStateError: LocalizedError {
    case accountMissing

    var errorDescription: String? {
        switch self {
        case .accountMissing:
            return "No account row exists to persist the background sync history cursor"
        }
    }
}

/// Manages persistent state for background sync (historyId, retry logic)
final class BackgroundSyncStateManager {
    private let makeBackgroundContext: () -> NSManagedObjectContext
    private let performBackgroundTask: (@escaping (NSManagedObjectContext) throws -> Void) async throws -> Void
    private let saveContext: (NSManagedObjectContext) throws -> Void

    private struct RetryState {
        var retryCount = 0
        var backoff: TimeInterval
    }

    private let retryState: OSAllocatedUnfairLock<RetryState>
    private let maxRetries: Int
    private let initialBackoffSeconds: TimeInterval
    private let maxBackoffSeconds: TimeInterval

    init(
        coreDataStack: CoreDataStack = .shared,
        maxRetries: Int = 3,
        initialBackoffSeconds: TimeInterval = 30,
        maxBackoffSeconds: TimeInterval = 3600
    ) {
        self.makeBackgroundContext = { coreDataStack.newBackgroundContext() }
        self.performBackgroundTask = { block in
            _ = try await coreDataStack.performBackgroundTask { context in
                try block(context)
            }
        }
        self.saveContext = { context in
            try coreDataStack.save(context: context)
        }
        self.maxRetries = maxRetries
        self.initialBackoffSeconds = initialBackoffSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
        self.retryState = OSAllocatedUnfairLock(initialState: RetryState(backoff: initialBackoffSeconds))
    }

    init(
        makeBackgroundContext: @escaping () -> NSManagedObjectContext,
        performBackgroundTask: @escaping (@escaping (NSManagedObjectContext) throws -> Void) async throws -> Void,
        saveContext: @escaping (NSManagedObjectContext) throws -> Void,
        maxRetries: Int = 3,
        initialBackoffSeconds: TimeInterval = 30,
        maxBackoffSeconds: TimeInterval = 3600
    ) {
        self.makeBackgroundContext = makeBackgroundContext
        self.performBackgroundTask = performBackgroundTask
        self.saveContext = saveContext
        self.maxRetries = maxRetries
        self.initialBackoffSeconds = initialBackoffSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
        self.retryState = OSAllocatedUnfairLock(initialState: RetryState(backoff: initialBackoffSeconds))
    }

    /// Retrieves the stored history ID from Core Data
    func getStoredHistoryId() async -> String? {
        let context = makeBackgroundContext()
        return await context.perform {
            let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
            fetchRequest.fetchLimit = 1

            do {
                let accounts = try context.fetch(fetchRequest)
                return accounts.first?.historyId
            } catch {
                Log.error("Failed to fetch historyId", category: .background, error: error)
                return nil
            }
        }
    }

    /// Stores the history ID in Core Data
    func storeHistoryId(_ historyId: String, accountEmail: String? = nil) async throws {
        let saveContext = self.saveContext
        try await performBackgroundTask { context in

            let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
            fetchRequest.fetchLimit = 1

            let accounts = try context.fetch(fetchRequest)
            let account: Account

            if let existingAccount = accounts.first {
                account = existingAccount
            } else {
                guard let accountEmail else {
                    throw BackgroundSyncStateError.accountMissing
                }

                guard let newAccount = NSEntityDescription.insertNewObject(
                    forEntityName: "Account",
                    into: context
                ) as? Account else {
                    throw CoreDataError.entityCreationFailed("Account")
                }

                newAccount.id = accountEmail
                newAccount.email = accountEmail
                newAccount.aliasesArray = []
                account = newAccount
            }

            account.historyId = historyId
            try saveContext(context)
        }
    }

    /// Increments retry count and returns whether we should retry
    /// Returns the backoff interval if we should retry, nil if we've exceeded max retries
    func incrementRetryAndGetBackoff() -> TimeInterval? {
        retryState.withLock { state in
            state.retryCount += 1

            if state.retryCount >= maxRetries {
                state.retryCount = 0
                state.backoff = initialBackoffSeconds
                return nil
            } else {
                state.backoff = min(state.backoff * 2, maxBackoffSeconds)
                return state.backoff
            }
        }
    }

    /// Resets retry count and backoff to initial values
    func resetRetryCount() {
        retryState.withLock { state in
            state.retryCount = 0
            state.backoff = initialBackoffSeconds
        }
    }
}
