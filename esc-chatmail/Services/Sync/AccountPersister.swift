import Foundation
import CoreData

/// Data structure for account information
struct AccountData {
    let historyId: String?
    let email: String
    let aliases: [String]
    let sendAsAliases: [SendAsAlias]
}

/// Errors that can occur during account persistence operations
enum AccountPersisterError: LocalizedError {
    case entityCreationFailed(String)
    case fetchFailed(Error)

    var errorDescription: String? {
        switch self {
        case .entityCreationFailed(let entityName):
            return "Failed to create \(entityName) entity in Core Data"
        case .fetchFailed(let underlyingError):
            return "Failed to fetch account: \(underlyingError.localizedDescription)"
        }
    }
}

extension MessagePersister {
    /// Saves or updates account information
    /// - Throws: AccountPersisterError.entityCreationFailed if Account entity cannot be created,
    ///           AccountPersisterError.fetchFailed if existing account lookup fails
    func saveAccount(
        profile: GmailProfile,
        aliases: [String],
        sendAsAliases: [SendAsAlias]? = nil,
        in context: NSManagedObjectContext,
        saveHistoryId: Bool = true
    ) async throws {
        try await context.perform {
            let validSendAsAliases = sendAsAliases.map(SendAsAlias.deduplicated)
            let request = Account.fetchRequest()
            request.predicate = NSPredicate(format: "email == %@", profile.emailAddress)

            do {
                if let existing = try context.fetch(request).first {
                    existing.aliasesArray = aliases
                    if let validSendAsAliases {
                        existing.sendAsAliasesArray = validSendAsAliases
                    } else if existing.sendAsAliasesArray.isEmpty {
                        existing.sendAsAliasesArray = Self.fallbackSendAsAliases(
                            accountEmail: profile.emailAddress,
                            aliases: aliases
                        )
                    }
                    if saveHistoryId {
                        existing.historyId = profile.historyId
                    }
                    Log.debug("Updated existing account: \(Log.redact(email: profile.emailAddress))", category: .sync)
                    return
                }
            } catch {
                Log.error("Failed to fetch existing account", category: .coreData, error: error)
                throw AccountPersisterError.fetchFailed(error)
            }

            guard let account = NSEntityDescription.insertNewObject(
                forEntityName: "Account",
                into: context
            ) as? Account else {
                Log.error("Failed to create Account entity", category: .coreData)
                throw AccountPersisterError.entityCreationFailed("Account")
            }
            account.id = profile.emailAddress
            account.email = profile.emailAddress
            account.historyId = saveHistoryId ? profile.historyId : nil
            account.aliasesArray = aliases
            account.sendAsAliasesArray = validSendAsAliases ?? Self.fallbackSendAsAliases(
                accountEmail: profile.emailAddress,
                aliases: aliases
            )
            let savedHistoryId = saveHistoryId ? profile.historyId : "nil"
            Log.info("Created new account: \(Log.redact(email: profile.emailAddress)) with historyId: \(savedHistoryId)", category: .sync)
        }
    }

    /// Fetches every account row so callers can enforce the single-account
    /// store invariant without selecting an arbitrary cursor first.
    func fetchAllAccountData() async throws -> [AccountData] {
        return try await coreDataStack.performBackgroundTask { context in
            let request = Account.fetchRequest()
            let accounts = try context.fetch(request)
            return accounts.map { account in
                AccountData(
                    historyId: account.historyId,
                    email: account.email,
                    aliases: account.aliasesArray,
                    sendAsAliases: account.sendAsAliasesArray
                )
            }
        }
    }

    func updateSendAsAliases(
        accountEmail: String,
        sendAsAliases: [SendAsAlias],
        in context: NSManagedObjectContext
    ) async {
        await context.perform {
            let validAliases = SendAsAlias.deduplicated(sendAsAliases)
            let request = Account.fetchRequest()
            request.predicate = NSPredicate(format: "email == %@", accountEmail)
            request.fetchLimit = 1

            guard let account = try? context.fetch(request).first else {
                Log.warning("No account found to update send-as aliases", category: .sync)
                return
            }

            account.aliasesArray = validAliases.map(\.emailAddress)
            account.sendAsAliasesArray = validAliases
            Log.debug("Updated send-as aliases for account: \(Log.redact(email: accountEmail))", category: .sync)
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

    /// Atomically finalizes a sync by setting the historyId and saving all pending changes in a single transaction.
    /// This prevents data loss if the app crashes between setting historyId and saving messages.
    /// - Parameters:
    ///   - historyId: Optional new history ID to set (nil if historyId should not be updated)
    ///   - context: The Core Data context containing all pending sync changes
    /// - Throws: CoreDataError.saveFailed if the save fails
    func finalizeSync(historyId: String?, in context: NSManagedObjectContext) async throws {
        try await context.perform {
            // Set historyId if provided
            if let historyId = historyId {
                let request = Account.fetchRequest()
                request.fetchLimit = 1
                if let account = try? context.fetch(request).first {
                    account.historyId = historyId
                    Log.debug("Finalizing sync with historyId: \(historyId)", category: .sync)
                } else {
                    Log.warning("No account found to set history ID during finalize", category: .sync)
                }
            }

            // Atomic save of all changes (messages + historyId together)
            guard context.hasChanges else { return }
            try context.save()
        }
    }
}

private extension MessagePersister {
    static func fallbackSendAsAliases(accountEmail: String, aliases: [String]) -> [SendAsAlias] {
        let allEmails = [accountEmail] + aliases
        return SendAsAlias.deduplicated(
            allEmails.map {
                SendAsAlias(
                    emailAddress: $0,
                    isDefault: $0.caseInsensitiveCompare(accountEmail) == .orderedSame,
                    isPrimary: $0.caseInsensitiveCompare(accountEmail) == .orderedSame,
                    verificationStatus: "accepted"
                )
            }
        )
    }
}
