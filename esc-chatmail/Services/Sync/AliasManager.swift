import Foundation
import CoreData

/// Centralized manager for user email aliases.
///
/// This actor consolidates alias loading logic that was previously duplicated across:
/// - InitialSyncOrchestrator (API fetch)
/// - IncrementalSyncOrchestrator (Core Data load)
/// - SyncEngine (Core Data load for background sync)
actor AliasManager {
    static let shared = AliasManager()

    private var cachedAliases: Set<String>?

    private init() {}

    // MARK: - Public API

    /// Returns cached aliases or loads from Core Data if not cached.
    ///
    /// - Parameter context: Core Data context to load from
    /// - Returns: Set of normalized user email aliases
    func getAliases(from context: NSManagedObjectContext) async -> Set<String> {
        if let cached = cachedAliases {
            return cached
        }

        let aliases = await loadFromCoreData(in: context)
        cachedAliases = aliases
        return aliases
    }

    /// Returns cached aliases without loading from Core Data.
    /// Returns empty set if no aliases are cached.
    func getCachedAliases() -> Set<String> {
        cachedAliases ?? []
    }

    /// Updates the cached aliases.
    /// Call this after fetching profile from API during initial sync.
    ///
    /// - Parameter aliases: The new set of normalized email aliases
    func setAliases(_ aliases: Set<String>) {
        cachedAliases = aliases
    }

    /// Clears the cached aliases.
    /// Call this on sign out or account change.
    func invalidate() {
        cachedAliases = nil
    }

    /// Returns true if aliases are currently cached.
    var hasCachedAliases: Bool {
        cachedAliases != nil && !(cachedAliases?.isEmpty ?? true)
    }

    // MARK: - Private

    private func loadFromCoreData(in context: NSManagedObjectContext) async -> Set<String> {
        await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1

            guard let account = try? context.fetch(request).first else {
                return Set<String>()
            }

            let aliases = ([account.email] + account.aliasesArray).map(normalizedEmail)
            return Set(aliases)
        }
    }
}

/// Global function for email normalization (consistent with existing codebase pattern)
private func normalizedEmail(_ email: String?) -> String {
    guard let email = email else { return "" }
    return EmailNormalizer.normalize(email)
}
