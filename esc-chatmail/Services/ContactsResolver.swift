import Foundation
import Contacts
import CoreData

// MARK: - ContactsResolver

/// Actor-based contacts resolver for avatar and display name lookup.
/// Uses actor isolation instead of manual DispatchQueue synchronization.
///
/// The implementation is split across multiple files:
/// - `Contacts/ContactMatch.swift`: ContactMatch class, protocol, errors
/// - `Contacts/ContactSearchService.swift`: CNContact search and matching
/// - `Contacts/ContactPersistenceService.swift`: Person Core Data updates
actor ContactsResolver: ContactsResolving {
    static let shared = ContactsResolver()

    // MARK: - Dependencies (internal for extensions)

    let contactStore = CNContactStore()
    let coreDataStack: CoreDataStack

    // MARK: - State

    private let cache = NSCache<NSString, ContactMatch>()
    private var authorizationStatus: CNAuthorizationStatus

    // MARK: - Initialization

    private init() {
        self.coreDataStack = CoreDataStack.shared
        self.cache.countLimit = 500
        self.authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    }

    // MARK: - ContactsResolving Protocol

    public func ensureAuthorization() async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        authorizationStatus = status

        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = try await contactStore.requestAccess(for: .contacts)
            authorizationStatus = granted ? .authorized : .denied
            if !granted {
                throw ContactsError.accessDenied
            }
        case .denied:
            throw ContactsError.accessDenied
        case .restricted:
            throw ContactsError.accessRestricted
        case .limited:
            // Limited access is treated as authorized for our purposes
            return
        @unknown default:
            throw ContactsError.accessDenied
        }
    }

    public func lookup(email: String) async -> ContactMatch? {
        let normalizedEmail = EmailNormalizer.normalize(email)

        // Check cache first
        if let cached = cache.object(forKey: normalizedEmail as NSString) {
            return cached
        }

        // Ensure we have authorization
        do {
            try await ensureAuthorization()
        } catch {
            Log.warning("Contacts authorization failed: \(error)", category: .general)
            return nil
        }

        // Search contacts (uses extension method)
        let match = searchContact(for: normalizedEmail)

        // Cache the result
        if let match = match {
            cache.setObject(match, forKey: normalizedEmail as NSString)

            // Update Person in Core Data (uses extension method)
            await updatePerson(email: normalizedEmail, match: match)
        }

        return match
    }

    public func prewarm(emails: [String]) async {
        // Ensure authorization once before batch lookups
        do {
            try await ensureAuthorization()
        } catch {
            Log.warning("Contacts authorization failed for prewarm: \(error)", category: .general)
            return
        }

        // Dedupe and normalize emails
        let uniqueEmails = Set(emails.map { EmailNormalizer.normalize($0) })

        // Populate cache for all unique emails
        for email in uniqueEmails {
            // Skip if already cached
            if cache.object(forKey: email as NSString) != nil {
                continue
            }
            // Search and cache
            if let match = searchContact(for: email) {
                cache.setObject(match, forKey: email as NSString)
            }
        }
    }

    // MARK: - Cache Management

    /// Invalidates cached contact data for a specific email.
    /// Call this after adding or editing a contact.
    public func invalidateCache(for email: String) {
        let normalizedEmail = EmailNormalizer.normalize(email)
        cache.removeObject(forKey: normalizedEmail as NSString)
    }

    /// Invalidates all cached contact data.
    /// Call this if a contact was modified and we don't know which emails changed.
    public func invalidateAllCache() {
        cache.removeAllObjects()
    }
}

// MARK: - Convenience Methods

extension ContactsResolver {

    /// Resolves just the display name for an email, with fallback to email local part.
    public func resolveDisplayName(for email: String) async -> String {
        if let match = await lookup(email: email),
           let displayName = match.displayName,
           !displayName.isEmpty {
            return displayName
        }

        // Fallback to email local part
        let normalized = EmailNormalizer.normalize(email)
        if let atIndex = normalized.firstIndex(of: "@") {
            return String(normalized[..<atIndex])
        }

        return email
    }

    /// Resolves just the avatar data for an email.
    public func resolveAvatarData(for email: String) async -> Data? {
        return await lookup(email: email)?.imageData
    }

    /// Batch resolve avatar data for multiple emails.
    /// Much more efficient than individual lookups when prefetching.
    public func resolveAvatarDataBatch(for emails: [String]) async -> [String: Data] {
        guard !emails.isEmpty else { return [:] }

        // Ensure we have authorization
        do {
            try await ensureAuthorization()
        } catch {
            Log.warning("Contacts authorization failed for batch lookup: \(error)", category: .general)
            return [:]
        }

        let normalizedEmails = Set(emails.map { EmailNormalizer.normalize($0) })

        // Uses extension method
        return performBatchLookup(for: normalizedEmails)
    }
}
