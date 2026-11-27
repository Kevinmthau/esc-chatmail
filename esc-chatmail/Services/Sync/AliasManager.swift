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
    /// Bumped by `invalidate()`. `getAliases` is the one entry that suspends (its Core
    /// Data load), so a load that was in flight when the caches were invalidated (a
    /// sign-in over another account's store resets the store between the read and the
    /// write, and `AuthSession.performDurableLocalCleanup` invalidates after the reset)
    /// returns what it read, since its caller asked under the old account, but caches
    /// nothing: cached, the old row's addresses would be the new account's own until the
    /// first sync's profile fetch (architecture review 2026-11, account-boundary-auth#2).
    private var invalidationEpoch: UInt64 = 0

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
            let epoch = invalidationEpoch
            guard let loaded = await loadFromCoreData(in: context) else {
                // A failed read is not an account with no addresses (CLAUDE.md: a
                // failed Core Data read is never "empty"). Cached, the empty set kept
                // the user's own address in every hash until a sync's `setAliases`,
                // and a send in that window forked its chat (architecture review
                // 2026-11, observability-errors#6). Nothing is cached: the next call
                // reads again.
                return []
            }
            accountAliases = loaded
            guard epoch == invalidationEpoch else {
                // Invalidated while the load was suspended: answer, cache nothing.
                return aliases(for: accountAliases)
            }
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
        invalidationEpoch &+= 1
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

    /// The user's own addresses for these account aliases: the account's and those
    /// Contacts add, with nothing stored.
    private func aliases(for accountAliases: AccountAliases) -> Set<String> {
        accountAliases.normalized.union(
            normalizeAliases(contactSelfAddresses(accountAliases.normalized))
        )
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

    /// The stored account's addresses: an empty set for a store with no Account row,
    /// and nil where the row could not be read, which is not the same thing.
    private func loadFromCoreData(in context: NSManagedObjectContext) async -> AccountAliases? {
        await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1

            let storedAccount: Account?
            do {
                storedAccount = try context.fetch(request).first
            } catch {
                Log.error("Failed to read the account's aliases", category: .sync, error: error)
                return nil
            }
            guard let account = storedAccount else {
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
