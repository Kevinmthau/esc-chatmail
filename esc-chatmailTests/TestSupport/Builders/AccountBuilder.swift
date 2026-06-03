import Foundation
import CoreData
@testable import esc_chatmail

/// Fluent builder for creating Account entities in tests.
///
/// Usage:
/// ```swift
/// let account = AccountBuilder()
///     .withId("user-123")
///     .withEmail("user@example.com")
///     .withHistoryId("12345")
///     .build(in: context)
/// ```
final class AccountBuilder {
    private var id: String = "test-account-id"
    private var email: String = "test@example.com"
    private var historyId: String? = "100000"
    private var aliases: [String] = []

    // MARK: - Fluent Setters

    func withId(_ id: String) -> Self {
        self.id = id
        return self
    }

    func withEmail(_ email: String) -> Self {
        self.email = email
        return self
    }

    func withHistoryId(_ historyId: String?) -> Self {
        self.historyId = historyId
        return self
    }

    func withAliases(_ aliases: [String]) -> Self {
        self.aliases = aliases
        return self
    }

    func addAlias(_ alias: String) -> Self {
        self.aliases.append(alias)
        return self
    }

    func noHistoryId() -> Self {
        self.historyId = nil
        return self
    }

    // MARK: - Build

    /// Builds the Account entity in the given context.
    /// - Parameter context: The managed object context to create the account in
    /// - Returns: The created Account entity
    @discardableResult
    func build(in context: NSManagedObjectContext) -> Account {
        let account = context.insertTestObject(Account.self)
        account.id = id
        account.email = email
        account.historyId = historyId
        account.aliasesArray = aliases
        return account
    }
}

// MARK: - Convenience Extensions

extension AccountBuilder {
    /// Creates a simple test account with minimal configuration
    static func simple(in context: NSManagedObjectContext) -> Account {
        AccountBuilder().build(in: context)
    }

    /// Creates an account with the given email
    static func withEmail(_ email: String, in context: NSManagedObjectContext) -> Account {
        AccountBuilder()
            .withEmail(email)
            .build(in: context)
    }

    /// Creates an account with aliases (for testing alias exclusion from participant hash)
    static func withAliases(_ email: String, aliases: [String], in context: NSManagedObjectContext) -> Account {
        AccountBuilder()
            .withEmail(email)
            .withAliases(aliases)
            .build(in: context)
    }

    /// Creates an account without history ID (simulates fresh sync state)
    static func fresh(email: String, in context: NSManagedObjectContext) -> Account {
        AccountBuilder()
            .withEmail(email)
            .noHistoryId()
            .build(in: context)
    }
}
