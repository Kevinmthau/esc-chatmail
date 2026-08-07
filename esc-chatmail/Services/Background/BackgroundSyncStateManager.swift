import Foundation
import CoreData
import os

struct BackgroundSyncContinuationState: Codable, Equatable {
    enum Mode: String, Codable {
        case history
        case partial
    }

    let mode: Mode
    /// The page where the next chunk begins. Partial-sync checkpoints may use
    /// `nil` to represent the first page before enumeration has started.
    let pageToken: String?
    let startHistoryId: String?
    let query: String?
    let maxResults: Int?
    let accountEmail: String?
    /// Mailbox cursor captured before a partial-sync scan begins. It is
    /// carried across every continuation page and committed only after the
    /// scan and message processing complete without failures.
    let watermarkHistoryId: String?

    static func history(startHistoryId: String, pageToken: String, accountEmail: String? = nil) -> Self {
        Self(
            mode: .history,
            pageToken: pageToken,
            startHistoryId: startHistoryId,
            query: nil,
            maxResults: nil,
            accountEmail: accountEmail,
            watermarkHistoryId: nil
        )
    }

    static func partial(
        query: String,
        pageToken: String?,
        maxResults: Int,
        startHistoryId: String?,
        watermarkHistoryId: String,
        accountEmail: String? = nil
    ) -> Self {
        Self(
            mode: .partial,
            pageToken: pageToken,
            // For partial recovery this is the cursor still stored locally
            // while the scan is in progress. It may be an expired non-nil
            // cursor, so compatibility cannot assume partial sync means nil.
            startHistoryId: startHistoryId,
            query: query,
            maxResults: maxResults,
            accountEmail: accountEmail,
            watermarkHistoryId: watermarkHistoryId
        )
    }

    func isCompatible(storedHistoryId: String?, currentAccountEmail: String?) -> Bool {
        guard let accountEmail,
              let currentAccountEmail,
              accountEmail.caseInsensitiveCompare(currentAccountEmail) == .orderedSame else {
            return false
        }

        switch mode {
        case .history:
            return startHistoryId == storedHistoryId
        case .partial:
            // Legacy partial continuations have no watermark and cannot safely
            // resume: restart them so the replacement scan captures one before
            // its first page. Otherwise require the source cursor to remain
            // unchanged until the terminal save installs the watermark.
            return watermarkHistoryId != nil && startHistoryId == storedHistoryId
        }
    }
}

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
    private enum DefaultsKeys {
        static let continuationState = "backgroundSync.continuationState"
    }

    private let makeBackgroundContext: () -> NSManagedObjectContext
    private let performBackgroundTask: (@escaping (NSManagedObjectContext) throws -> Void) async throws -> Void
    private let saveContext: (NSManagedObjectContext) throws -> Void
    private let defaults: UserDefaults

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
        defaults: UserDefaults = .standard,
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
        self.defaults = defaults
        self.maxRetries = maxRetries
        self.initialBackoffSeconds = initialBackoffSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
        self.retryState = OSAllocatedUnfairLock(initialState: RetryState(backoff: initialBackoffSeconds))
    }

    init(
        makeBackgroundContext: @escaping () -> NSManagedObjectContext,
        performBackgroundTask: @escaping (@escaping (NSManagedObjectContext) throws -> Void) async throws -> Void,
        saveContext: @escaping (NSManagedObjectContext) throws -> Void,
        defaults: UserDefaults = .standard,
        maxRetries: Int = 3,
        initialBackoffSeconds: TimeInterval = 30,
        maxBackoffSeconds: TimeInterval = 3600
    ) {
        self.makeBackgroundContext = makeBackgroundContext
        self.performBackgroundTask = performBackgroundTask
        self.saveContext = saveContext
        self.defaults = defaults
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

    func getContinuationState() -> BackgroundSyncContinuationState? {
        guard let data = defaults.data(forKey: DefaultsKeys.continuationState) else {
            return nil
        }

        do {
            return try JSONDecoder().decode(BackgroundSyncContinuationState.self, from: data)
        } catch {
            defaults.removeObject(forKey: DefaultsKeys.continuationState)
            Log.error("Failed to decode background sync continuation state", category: .background, error: error)
            return nil
        }
    }

    func storeContinuationState(_ continuationState: BackgroundSyncContinuationState) throws {
        let data = try JSONEncoder().encode(continuationState)
        defaults.set(data, forKey: DefaultsKeys.continuationState)
    }

    func clearContinuationState() {
        Self.clearContinuationState(in: defaults)
    }

    static func clearContinuationState(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: DefaultsKeys.continuationState)
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
