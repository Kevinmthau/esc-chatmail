import Foundation
import CoreData

/// Centralized manager for user email aliases.
///
/// This actor consolidates alias loading logic that was previously duplicated across:
/// - InitialSyncOrchestrator (API fetch)
/// - IncrementalSyncOrchestrator (Core Data load)
/// - SyncEngine (Core Data load for background sync)
///
/// The user's own addresses are the account's and its send-as addresses, and
/// those Contacts add as adopted by `ContactLinkedAddressStore`
/// (`selfAddressesSnapshot(forKnown:)`). Contacts are never read here: read
/// live, at every lookup, an edit to any card moved an address in or out of
/// the set between two hashes, and the set every hash leaves out must change
/// only where the stored conversations are brought onto it
/// (`DataCleanupService.unifyConversationsByContactIfNeeded`).
actor AliasManager {
    static let shared = AliasManager()

    private let contactSelfAddresses: @Sendable (Set<String>) -> Set<String>
    private let rollupDependencyTracker: any ParticipantRollupDependencyTracking
    private var cachedAliases: Set<String>?
    private var cachedAccountAliases: AccountAliases?
    private var cachedContactSelfAddresses: Set<String>?
    private var cachedDependencyFingerprint: ParticipantRollupDependencyFingerprint?

    /// - Parameter contactSelfAddresses: The addresses Contacts add for an
    ///   account with these normalized addresses; a synchronous read of the
    ///   adopted set, never of Contacts.
    init(
        contactSelfAddresses: @escaping @Sendable (Set<String>) -> Set<String> = {
            ContactLinkedAddressStore.shared.selfAddressesSnapshot(forKnown: $0)
        },
        rollupDependencyTracker: any ParticipantRollupDependencyTracking = ParticipantRollupDependencyTracker.shared
    ) {
        self.contactSelfAddresses = contactSelfAddresses
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
           cachedContactSelfAddresses == contactSelfAddresses(accountAliases.normalized),
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
           cachedContactSelfAddresses == contactSelfAddresses(accountAliases.normalized),
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
        cachedContactSelfAddresses = nil
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
        let fromContacts = contactSelfAddresses(accountAliases.normalized)
        let aliases = accountAliases.normalized.union(normalizeAliases(fromContacts))
        let previousAliases = cachedAliases

        cachedAccountAliases = accountAliases
        cachedContactSelfAddresses = fromContacts
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
}

private func normalizeAliases(_ aliases: some Sequence<String>) -> Set<String> {
    Set(
        aliases
            .map(EmailNormalizer.normalize)
            .filter { !$0.isEmpty }
    )
}
