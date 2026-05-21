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
    private let rollupDependencyTracker: any ParticipantRollupDependencyTracking
    private var cachedAliases: Set<String>?
    private var cachedAccountAliases: AccountAliases?
    private var cachedDependencyFingerprint: ParticipantRollupDependencyFingerprint?

    init(
        selfAliasProvider: any SelfAliasProviding = ContactsSelfAliasProvider.shared,
        rollupDependencyTracker: any ParticipantRollupDependencyTracking = ParticipantRollupDependencyTracker.shared
    ) {
        self.selfAliasProvider = selfAliasProvider
        self.rollupDependencyTracker = rollupDependencyTracker
    }

    // MARK: - Public API

    /// Returns cached aliases or loads from Core Data if not cached.
    ///
    /// - Parameter context: Core Data context to load from
    /// - Returns: Set of normalized user email aliases
    func getAliases(from context: NSManagedObjectContext) async -> Set<String> {
        if let cached = cachedAliases,
           let accountAliases = cachedAccountAliases,
           !cached.isEmpty,
           cachedDependencyFingerprint == rollupDependencyTracker.fingerprint(for: accountAliases.raw) {
            return cached
        }

        let accountAliases: AccountAliases
        if let cachedAccountAliases {
            accountAliases = cachedAccountAliases
        } else {
            accountAliases = await loadFromCoreData(in: context)
        }
        return await cacheAliases(for: accountAliases)
    }

    /// Returns cached aliases without loading from Core Data.
    /// Returns empty set if no aliases are cached.
    func getCachedAliases() async -> Set<String> {
        guard let accountAliases = cachedAccountAliases else {
            return cachedAliases ?? []
        }

        if let cached = cachedAliases,
           !cached.isEmpty,
           cachedDependencyFingerprint == rollupDependencyTracker.fingerprint(for: accountAliases.raw) {
            return cached
        }

        return await cacheAliases(for: accountAliases)
    }

    /// Updates the cached aliases.
    /// Call this after fetching profile from API during initial sync.
    ///
    /// - Parameter aliases: The new set of normalized email aliases
    @discardableResult
    func setAliases(_ aliases: Set<String>) async -> Set<String> {
        let accountAliases = AccountAliases(
            normalized: normalizeAliases(aliases),
            raw: Array(aliases)
        )
        return await cacheAliases(for: accountAliases)
    }

    /// Clears the cached aliases.
    /// Call this on sign out or account change.
    func invalidate() {
        cachedAliases = nil
        cachedAccountAliases = nil
        cachedDependencyFingerprint = nil
        rollupDependencyTracker.invalidateAll()
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

    private func cacheAliases(for accountAliases: AccountAliases) async -> Set<String> {
        let aliases = await aliasesIncludingSelfContactAliases(
            normalizedAliases: accountAliases.normalized,
            rawEmails: accountAliases.raw
        )
        let previousAliases = cachedAliases

        cachedAccountAliases = accountAliases
        cachedAliases = aliases

        if previousAliases != aliases {
            rollupDependencyTracker.invalidateAll()
        }
        cachedDependencyFingerprint = rollupDependencyTracker.fingerprint(for: accountAliases.raw)
        return aliases
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
