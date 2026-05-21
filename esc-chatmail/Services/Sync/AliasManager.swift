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

    private let selfAliasProvider: any SelfAliasProviding
    private var cachedAliases: Set<String>?

    init(selfAliasProvider: any SelfAliasProviding = ContactsSelfAliasProvider.shared) {
        self.selfAliasProvider = selfAliasProvider
    }

    // MARK: - Public API

    /// Returns cached aliases or loads from Core Data if not cached.
    ///
    /// - Parameter context: Core Data context to load from
    /// - Returns: Set of normalized user email aliases
    func getAliases(from context: NSManagedObjectContext) async -> Set<String> {
        if let cached = cachedAliases, !cached.isEmpty {
            return cached
        }

        let accountAliases = await loadFromCoreData(in: context)
        let aliases = await aliasesIncludingSelfContactAliases(
            normalizedAliases: accountAliases.normalized,
            rawEmails: accountAliases.raw
        )
        cachedAliases = aliases
        ParticipantRollupDependencyTracker.shared.invalidateAll()
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
    @discardableResult
    func setAliases(_ aliases: Set<String>) async -> Set<String> {
        let normalizedAliases = normalizeAliases(aliases)
        let aliases = await aliasesIncludingSelfContactAliases(
            normalizedAliases: normalizedAliases,
            rawEmails: Array(aliases)
        )
        cachedAliases = aliases
        ParticipantRollupDependencyTracker.shared.invalidateAll()
        return aliases
    }

    /// Clears the cached aliases.
    /// Call this on sign out or account change.
    func invalidate() {
        cachedAliases = nil
        ParticipantRollupDependencyTracker.shared.invalidateAll()
    }

    /// Returns true if aliases are currently cached.
    var hasCachedAliases: Bool {
        cachedAliases != nil && !(cachedAliases?.isEmpty ?? true)
    }

    // MARK: - Private

    private struct AccountAliases: Sendable {
        let normalized: Set<String>
        let raw: [String]
    }

    private func loadFromCoreData(in context: NSManagedObjectContext) async -> AccountAliases {
        await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1

            guard let account = try? context.fetch(request).first else {
                return AccountAliases(normalized: [], raw: [])
            }

            let rawAliases = [account.email] + account.aliasesArray
            return AccountAliases(
                normalized: normalizeAliases(rawAliases),
                raw: rawAliases
            )
        }
    }

    private func aliasesIncludingSelfContactAliases(
        normalizedAliases: Set<String>,
        rawEmails: [String]
    ) async -> Set<String> {
        let selfContactAliases = await selfAliasProvider.aliases(knownEmails: rawEmails)
        return normalizedAliases.union(normalizeAliases(selfContactAliases))
    }
}

private func normalizeAliases(_ aliases: some Sequence<String>) -> Set<String> {
    Set(
        aliases
            .map(EmailNormalizer.normalize)
            .filter { !$0.isEmpty }
    )
}
