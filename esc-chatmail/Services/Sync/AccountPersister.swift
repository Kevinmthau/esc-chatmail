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
    /// The store has no `Account` row to stage the history cursor on: the run belongs to an
    /// account that is no longer there, and its save must not commit without a cursor.
    case accountMissing

    var errorDescription: String? {
        switch self {
        case .entityCreationFailed(let entityName):
            return "Failed to create \(entityName) entity in Core Data"
        case .fetchFailed(let underlyingError):
            return "Failed to fetch account: \(underlyingError.localizedDescription)"
        case .accountMissing:
            return "No account row to stage the history cursor on"
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

    /// Stages the Account's history cursor into the caller's context and saves nothing: the
    /// cursor commits with the run's final save or dies with it (CLAUDE.md, sync cursor).
    /// A failed read is never "no account". It throws `AccountPersisterError.fetchFailed`, so the
    /// run ends with no save and a ledger or counter that moved cannot commit beside a cursor that
    /// did not. A store with no `Account` row throws `.accountMissing` for the same reason. Until
    /// 2026-11-27 both were a logged warning, and the run committed with its cursor left where it
    /// was (architecture review 2026-11, sync-engine#6 and observability-errors#6).
    /// - Parameters:
    ///   - historyId: The new history ID to stage
    ///   - context: The sync context to stage it in (not saved here)
    func setAccountHistoryId(_ historyId: String, in context: NSManagedObjectContext) async throws {
        try await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            let account: Account?
            do {
                account = try context.fetch(request).first
            } catch {
                throw AccountPersisterError.fetchFailed(error)
            }
            guard let account else { throw AccountPersisterError.accountMissing }
            account.historyId = historyId
            Log.debug("Set historyId to \(historyId) in context (pending save)", category: .sync)
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
