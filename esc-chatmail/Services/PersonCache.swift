import Foundation
import CoreData

/// Thread-safe cache for Person entities to avoid N+1 query problems in conversation lists
/// Uses actor isolation for automatic thread-safety instead of @MainActor
actor PersonCache {
    static let shared = PersonCache()

    // In-memory cache: email -> Person
    private var cache: [String: CachedPerson] = [:]
    private let coreDataStack = CoreDataStack.shared

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

    private init() {}

    /// Prefetch Person entities for a batch of emails to avoid N+1 queries
    func prefetch(emails: [String]) async {
        let normalized = emails.map { EmailNormalizer.normalize($0) }

        // Filter out already cached emails
        let uncached = normalized.filter { email in
            if let cached = cache[email], !cached.isExpired {
                return false
            }
            return true
        }

        guard !uncached.isEmpty else { return }

        // Batch fetch from Core Data in background
        let context = coreDataStack.newBackgroundContext()

        let personsData: [(email: String, displayName: String?)] = await Task.detached {
            await context.perform {
                let request = Person.fetchRequest()
                request.predicate = NSPredicate(format: "email IN %@", uncached)
                request.fetchBatchSize = 50

                do {
                    let persons = try context.fetch(request)
                    return persons.map { person in
                        (person.email, person.displayName)
                    }
                } catch {
                    Log.error("Failed to prefetch Person entities", category: .coreData, error: error)
                    return []
                }
            }
        }.value

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
    }

    /// Get cached Person display name, returns nil if not in cache
    func getCachedDisplayName(for email: String) -> String? {
        let normalized = EmailNormalizer.normalize(email)

        if let cached = cache[normalized], !cached.isExpired {
            return cached.displayName
        }

        return nil
    }

    /// Get Person display name, fetching from DB if not cached
    func getDisplayName(for email: String) async -> String {
        let normalized = EmailNormalizer.normalize(email)

        // Check cache first
        if let cached = cache[normalized], !cached.isExpired {
            return cached.displayName ?? fallbackDisplayName(for: email)
        }

        // Fetch from Core Data in background to avoid blocking main thread
        let context = coreDataStack.newBackgroundContext()
        let displayName: String? = await Task.detached {
            await context.perform {
                let request = Person.fetchRequest()
                request.predicate = NSPredicate(format: "email == %@", normalized)
                request.fetchLimit = 1
                return try? context.fetch(request).first?.displayName
            }
        }.value

        // Cache the result (actor-isolated)
        cache[normalized] = CachedPerson(
            displayName: displayName,
            email: normalized,
            cachedAt: Date()
        )

        return displayName ?? fallbackDisplayName(for: email)
    }

    /// Clear expired cache entries
    func cleanupExpiredEntries() {
        cache = cache.filter { !$0.value.isExpired }
    }

    /// Clear all cached entries
    func clearCache() {
        cache.removeAll()
    }

    /// Get fallback display name from email, formatted as a proper name
    private func fallbackDisplayName(for email: String) -> String {
        EmailNormalizer.formatAsDisplayName(email: email)
    }
}
