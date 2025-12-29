import Foundation
import CoreData

/// Data structure for account information
struct AccountData {
    let historyId: String?
    let email: String
    let aliases: [String]
}

extension MessagePersister {
    /// Saves or updates account information
    func saveAccount(
        profile: GmailProfile,
        aliases: [String],
        in context: NSManagedObjectContext
    ) async -> Account {
        let request = Account.fetchRequest()
        request.predicate = NSPredicate(format: "email == %@", profile.emailAddress)

        if let existing = try? context.fetch(request).first {
            existing.aliasesArray = aliases
            existing.historyId = profile.historyId
            Log.debug("Updated existing account: \(profile.emailAddress)", category: .sync)
            return existing
        }

        let account = NSEntityDescription.insertNewObject(
            forEntityName: "Account",
            into: context
        ) as! Account
        account.id = profile.emailAddress
        account.email = profile.emailAddress
        account.historyId = profile.historyId
        account.aliasesArray = aliases
        Log.info("Created new account: \(profile.emailAddress) with historyId: \(profile.historyId)", category: .sync)
        return account
    }

    /// Fetches account data
    func fetchAccountData() async throws -> AccountData? {
        return try await coreDataStack.performBackgroundTask { context in
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            let accounts = try context.fetch(request)
            guard let account = accounts.first else {
                return nil
            }
            return AccountData(
                historyId: account.historyId,
                email: account.email,
                aliases: account.aliasesArray
            )
        }
    }

    /// Updates account's history ID in the provided context WITHOUT saving
    /// Use this for transactional updates where historyId should be saved with other changes
    /// - Parameters:
    ///   - historyId: The new history ID to set
    ///   - context: The Core Data context to update in (will not be saved)
    func setAccountHistoryId(_ historyId: String, in context: NSManagedObjectContext) async {
        await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            if let account = try? context.fetch(request).first {
                account.historyId = historyId
                Log.debug("Set historyId to \(historyId) in context (pending save)", category: .sync)
            } else {
                Log.warning("No account found to set history ID", category: .sync)
            }
        }
    }

    /// Updates account's history ID in a SEPARATE transaction
    /// WARNING: Use setAccountHistoryId(_:in:) for transactional sync updates
    /// This method is only for standalone historyId updates outside of sync
    /// - Parameter historyId: The new history ID to save
    /// - Returns: true if the save succeeded, false if it failed after retries
    @available(*, deprecated, message: "Use setAccountHistoryId(_:in:) for transactional sync updates")
    @discardableResult
    func updateAccountHistoryId(_ historyId: String) async -> Bool {
        var lastError: Error?

        // First attempt
        do {
            try await coreDataStack.performBackgroundTask { [weak self] context in
                guard let self = self else { return }
                let request = Account.fetchRequest()
                request.fetchLimit = 1
                if let account = try context.fetch(request).first {
                    account.historyId = historyId
                    try self.coreDataStack.save(context: context)
                    Log.debug("Successfully updated history ID to: \(historyId)", category: .sync)
                } else {
                    Log.warning("No account found to update history ID", category: .sync)
                }
            }
            return true
        } catch {
            lastError = error
            Log.warning("Failed to save history ID (attempt 1): \(error.localizedDescription)", category: .sync)
        }

        // Retry with backoff
        for attempt in 2...3 {
            do {
                // Exponential backoff: 500ms, 1s
                let delay = UInt64(250_000_000 * (1 << (attempt - 1)))
                try await Task.sleep(nanoseconds: delay)

                try await coreDataStack.performBackgroundTask { [weak self] context in
                    guard let self = self else { return }
                    let request = Account.fetchRequest()
                    request.fetchLimit = 1
                    if let account = try context.fetch(request).first {
                        account.historyId = historyId
                        try self.coreDataStack.save(context: context)
                        Log.debug("Successfully saved history ID on retry attempt \(attempt)", category: .sync)
                    }
                }
                return true
            } catch {
                lastError = error
                Log.warning("Failed to save history ID (attempt \(attempt)): \(error.localizedDescription)", category: .sync)
            }
        }

        Log.error("Failed to save history ID after all retries. Last error: \(lastError?.localizedDescription ?? "unknown")", category: .sync)
        return false
    }
}
