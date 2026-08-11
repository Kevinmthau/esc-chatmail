import Foundation
import CoreData

/// Synchronous account-generation fence shared by participant caches.
///
/// Actor generation checks protect actor-owned memory. The lock-backed token
/// additionally lets Core Data `perform` blocks make a final synchronous
/// admission decision without reaching back into an actor. Invalidating a
/// token linearizes account teardown with those context-queue decisions.
final class ParticipantCacheAccountGenerationToken: @unchecked Sendable {
    let value: UInt64

    private let lock = NSLock()
    private var active = true

    init(value: UInt64) {
        self.value = value
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }

    /// Runs a synchronous persistence decision only while this generation is
    /// active. `invalidate()` cannot return until an already-admitted body has
    /// completed, so AuthSession can safely reset the store after draining.
    func withActiveGeneration<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return nil }
        return body()
    }
}

/// Thread-safe cache for Person entities to avoid N+1 query problems in conversation lists
/// Uses actor isolation for automatic thread-safety instead of @MainActor
actor PersonCache: PeriodicCleanupHandler {
    static let shared = PersonCache()

    // In-memory cache: email -> Person
    private var cache: [String: CachedPerson] = [:]
    private let fetchPersons: @Sendable ([String]) async -> [(email: String, displayName: String?)]
    private let fetchDisplayName: @Sendable (String) async -> String?

    /// Periodic cleanup task helper
    private let cleanupTask = PeriodicCleanupTask()

    /// Maximum cache size to prevent unbounded growth when cleanup is delayed
    private let maxCacheSize = 1000

    private var acceptsAccountWork = true
    private var accountGeneration: UInt64 = 0
    private var accountGenerationToken = ParticipantCacheAccountGenerationToken(value: 0)
    private var activeOperationCounts: [UInt64: Int] = [:]
    private var drainWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

    // Cache entry with timestamp for expiration
    private struct CachedPerson: Sendable {
        let displayName: String?
        let email: String
        let cachedAt: Date

        var isExpired: Bool {
            // Expire after 5 minutes
            Date().timeIntervalSince(cachedAt) > 300
        }
    }

    /// The injected fetches and cleanup toggle keep account-boundary tests
    /// hermetic; production uses the shared Core Data stack and periodic task.
    init(
        coreDataStack: CoreDataStack = .shared,
        startsPeriodicCleanup: Bool = true,
        fetchPersons: (@Sendable ([String]) async -> [(email: String, displayName: String?)])? = nil,
        fetchDisplayName: (@Sendable (String) async -> String?)? = nil
    ) {
        self.fetchPersons = fetchPersons ?? { emails in
            let context = coreDataStack.newBackgroundContext()
            return await context.perform {
                let request = Person.fetchRequest()
                request.predicate = NSPredicate(format: "email IN %@", emails)
                request.fetchBatchSize = 50

                do {
                    return try context.fetch(request).map { person in
                        (person.email, person.displayName)
                    }
                } catch {
                    Log.error("Failed to prefetch Person entities", category: .coreData, error: error)
                    return []
                }
            }
        }
        self.fetchDisplayName = fetchDisplayName ?? { email in
            let context = coreDataStack.newBackgroundContext()
            return await context.perform {
                let request = Person.fetchRequest()
                request.predicate = NSPredicate(format: "email == %@", email)
                request.fetchLimit = 1
                return try? context.fetch(request).first?.displayName
            }
        }

        if startsPeriodicCleanup {
            // Start periodic cleanup in a separate task to comply with Swift 6 actor init rules.
            Task { self.cleanupTask.start(handler: self, interval: .minutes(5), runImmediately: false) }
        }
    }

    // MARK: - PeriodicCleanupHandler

    func performCleanup() async {
        cleanupExpiredEntries()
    }

    /// Prefetch Person entities for a batch of emails to avoid N+1 queries
    func prefetch(emails: [String]) async {
        guard let generation = beginAccountOperation() else { return }
        defer { finishAccountOperation(generation) }

        let normalized = emails.map { EmailNormalizer.normalize($0) }

        // Filter out already cached emails
        let uncached = normalized.filter { email in
            if let cached = cache[email], !cached.isExpired {
                return false
            }
            return true
        }

        guard !uncached.isEmpty else { return }

        let personsData = await fetchPersons(uncached)
        guard isCurrentAccountGeneration(generation) else { return }

        // Update cache (actor-isolated)
        let now = Date()
        for (email, displayName) in personsData {
            cache[email] = CachedPerson(
                displayName: displayName,
                email: email,
                cachedAt: now
            )
        }

        // Add entries for emails not found in DB (to avoid repeated lookups)
        for email in uncached {
            if cache[email] == nil {
                cache[email] = CachedPerson(
                    displayName: nil,
                    email: email,
                    cachedAt: now
                )
            }
        }

        // Enforce max size to prevent unbounded growth
        enforceMaxSize()
    }

    /// Get cached Person display name, returns nil if not in cache
    func getCachedDisplayName(for email: String) -> String? {
        guard acceptsAccountWork else { return nil }
        let normalized = EmailNormalizer.normalize(email)

        if let cached = cache[normalized], !cached.isExpired {
            return cached.displayName
        }

        return nil
    }

    /// Get Person display name, fetching from DB if not cached
    func getDisplayName(for email: String) async -> String {
        guard let generation = beginAccountOperation() else {
            return PersonDisplayNameResolver.fallbackConversationName()
        }
        defer { finishAccountOperation(generation) }

        let normalized = EmailNormalizer.normalize(email)

        // Check cache first
        if let cached = cache[normalized], !cached.isExpired {
            return PersonDisplayNameResolver.sanitizedRealDisplayName(
                cached.displayName,
                forEmail: email
            ) ?? PersonDisplayNameResolver.fallbackConversationName()
        }

        let displayName = await fetchDisplayName(normalized)
        guard isCurrentAccountGeneration(generation) else {
            return PersonDisplayNameResolver.fallbackConversationName()
        }

        // Cache the result (actor-isolated)
        cache[normalized] = CachedPerson(
            displayName: displayName,
            email: normalized,
            cachedAt: Date()
        )

        // Enforce max size to prevent unbounded growth
        enforceMaxSize()

        return PersonDisplayNameResolver.sanitizedRealDisplayName(
            displayName,
            forEmail: email
        ) ?? PersonDisplayNameResolver.fallbackConversationName()
    }

    /// Clear expired cache entries
    func cleanupExpiredEntries() {
        cache = cache.filter { !$0.value.isExpired }
    }

    /// Enforces maximum cache size by removing oldest entries when exceeded
    private func enforceMaxSize() {
        guard cache.count > maxCacheSize else { return }

        // Remove oldest entries (by cachedAt timestamp) until we're under the limit
        let sortedEntries = cache.sorted { $0.value.cachedAt < $1.value.cachedAt }
        let entriesToRemove = cache.count - maxCacheSize

        for (key, _) in sortedEntries.prefix(entriesToRemove) {
            cache.removeValue(forKey: key)
        }
    }

    /// Clear all cached entries
    func clearCache() {
        cache.removeAll()
        ParticipantRollupDependencyTracker.shared.invalidateAll()
    }

    /// Closes admission, invalidates every suspended read, clears memory, and
    /// waits for old-generation operations before AuthSession resets Core Data.
    func closeAccountWorkAndClear() async {
        let closingGeneration = accountGeneration
        if acceptsAccountWork {
            acceptsAccountWork = false
            accountGenerationToken.invalidate()
        }
        clearCache()
        await waitForAccountOperationsToDrain(generation: closingGeneration)
    }

    /// Opens a distinct generation. A request started after this point cannot
    /// observe or publish an old generation's suspended Core Data result.
    func reopenAccountWork() {
        guard !acceptsAccountWork else { return }
        accountGeneration &+= 1
        accountGenerationToken = ParticipantCacheAccountGenerationToken(value: accountGeneration)
        acceptsAccountWork = true
    }

    func captureAccountGeneration() -> ParticipantCacheAccountGenerationToken? {
        guard acceptsAccountWork else { return nil }
        return accountGenerationToken
    }

    /// Invalidates a specific cache entry by email.
    /// Use this when a Person entity is updated or deleted.
    func invalidateEntry(for email: String) {
        let normalized = EmailNormalizer.normalize(email)
        cache.removeValue(forKey: normalized)
        ParticipantRollupDependencyTracker.shared.invalidate(email: normalized)
    }

    private func beginAccountOperation() -> ParticipantCacheAccountGenerationToken? {
        guard acceptsAccountWork, accountGenerationToken.isActive else { return nil }
        let generation = accountGenerationToken
        activeOperationCounts[generation.value, default: 0] += 1
        return generation
    }

    private func finishAccountOperation(_ generation: ParticipantCacheAccountGenerationToken) {
        let remaining = max((activeOperationCounts[generation.value] ?? 1) - 1, 0)
        if remaining == 0 {
            activeOperationCounts[generation.value] = nil
            let waiters = drainWaiters.removeValue(forKey: generation.value) ?? []
            waiters.forEach { $0.resume() }
        } else {
            activeOperationCounts[generation.value] = remaining
        }
    }

    private func waitForAccountOperationsToDrain(generation: UInt64) async {
        guard (activeOperationCounts[generation] ?? 0) > 0 else { return }
        await withCheckedContinuation { continuation in
            drainWaiters[generation, default: []].append(continuation)
        }
    }

    private func isCurrentAccountGeneration(
        _ generation: ParticipantCacheAccountGenerationToken
    ) -> Bool {
        acceptsAccountWork
            && generation.value == accountGeneration
            && generation === accountGenerationToken
            && generation.isActive
    }

}
