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

    let contactStore: CNContactStore
    let coreDataStack: CoreDataStack
    let saveAvatar: @Sendable (String, Data) async -> String?

    // MARK: - State

    private let cache = NSCache<NSString, ContactMatch>()
    private var authorizationStatus: CNAuthorizationStatus
    private let authorizationStatusProvider: () -> CNAuthorizationStatus
    private let accessRequester: () async throws -> Bool
    private let contactLookup: ((String) -> ContactMatch?)?
    /// Deduplicates concurrent permission requests: CNContactStore misbehaves
    /// when requestAccess is invoked multiple times in flight (the CI/on-device
    /// hang class), so every caller awaits the one stored request.
    private var accessRequestTask: Task<CNAuthorizationStatus, Never>?
    private var acceptsAccountWork = true
    private var accountGeneration: UInt64 = 0
    private var accountGenerationToken = ParticipantCacheAccountGenerationToken(value: 0)
    private var activeOperationCounts: [UInt64: Int] = [:]
    private var drainWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

    // MARK: - Initialization

    /// The status-provider and access-requester parameters are testing seams;
    /// production code uses `shared`.
    init(
        authorizationStatusProvider: @escaping () -> CNAuthorizationStatus = {
            CNContactStore.authorizationStatus(for: .contacts)
        },
        accessRequester: (() async throws -> Bool)? = nil,
        coreDataStack: CoreDataStack = .shared,
        contactLookup: ((String) -> ContactMatch?)? = nil,
        saveAvatar: @escaping @Sendable (String, Data) async -> String? = { email, data in
            AvatarStorage.shared.saveAvatar(for: email, imageData: data)
        }
    ) {
        let store = CNContactStore()
        self.contactStore = store
        self.coreDataStack = coreDataStack
        self.contactLookup = contactLookup
        self.saveAvatar = saveAvatar
        self.cache.countLimit = 500
        self.authorizationStatusProvider = authorizationStatusProvider
        self.accessRequester = accessRequester ?? { try await store.requestAccess(for: .contacts) }
        self.authorizationStatus = authorizationStatusProvider()
    }

    // MARK: - ContactsResolving Protocol

    /// Verifies contacts access without ever presenting the permission dialog.
    /// `.notDetermined` throws immediately so lookups degrade to header/stored
    /// names instead of suspending behind the prompt; the deliberate prompt
    /// lives in `requestAccessIfNeeded()`.
    public func ensureAuthorization() async throws {
        let status = authorizationStatusProvider()
        authorizationStatus = status

        if status == .authorized {
            return
        }

        if #available(iOS 18.0, *), status == .limited {
            // Limited access is treated as authorized for our purposes.
            return
        }

        if status == .notDetermined {
            throw ContactsError.accessNotDetermined
        }

        if status == .denied {
            throw ContactsError.accessDenied
        }

        if status == .restricted {
            throw ContactsError.accessRestricted
        }

        // Fail closed for any future/unknown status values.
        throw ContactsError.accessDenied
    }

    /// The single deliberate permission entry point. Presents the system dialog
    /// when status is `.notDetermined`, deduplicating concurrent callers onto
    /// one CNContactStore request. On grant, drops cached negative matches so
    /// resolution picks up address-book data immediately.
    @discardableResult
    public func requestAccessIfNeeded() async -> CNAuthorizationStatus {
        if let accessRequestTask {
            return await accessRequestTask.value
        }

        let status = authorizationStatusProvider()
        authorizationStatus = status
        guard status == .notDetermined else {
            return status
        }

        let requestTask = Task<CNAuthorizationStatus, Never> { [accessRequester, authorizationStatusProvider] in
            _ = try? await accessRequester()
            return authorizationStatusProvider()
        }
        accessRequestTask = requestTask
        let updatedStatus = await requestTask.value
        accessRequestTask = nil
        authorizationStatus = updatedStatus

        if isUsableAuthorizationStatus(updatedStatus) {
            invalidateAllCache()
        }

        return updatedStatus
    }

    private func isUsableAuthorizationStatus(_ status: CNAuthorizationStatus) -> Bool {
        if status == .authorized {
            return true
        }
        if #available(iOS 18.0, *), status == .limited {
            return true
        }
        return false
    }

    public func lookup(email: String) async -> ContactMatch? {
        guard let generation = beginAccountOperation() else { return nil }
        defer { finishAccountOperation(generation) }

        let normalizedEmail = EmailNormalizer.normalize(email)

        // Check cache first
        if let cached = cache.object(forKey: normalizedEmail as NSString) {
            return cached
        }

        // Ensure we have authorization
        do {
            try await ensureAuthorization()
        } catch {
            logAuthorizationFailure(error, operation: "lookup")
            return nil
        }
        guard isCurrentAccountGeneration(generation) else { return nil }

        // Search contacts (uses extension method)
        let match: ContactMatch?
        if let contactLookup {
            match = contactLookup(normalizedEmail)
        } else {
            match = searchContact(for: normalizedEmail)
        }

        // Cache the result
        if let match = match {
            cache.setObject(match, forKey: normalizedEmail as NSString)

            // Update Person in Core Data (uses extension method)
            await updatePerson(
                email: normalizedEmail,
                match: match,
                accountGeneration: generation
            )
        }

        return isCurrentAccountGeneration(generation) ? match : nil
    }

    public func prewarm(emails: [String]) async {
        guard let generation = beginAccountOperation() else { return }
        defer { finishAccountOperation(generation) }

        // Ensure authorization once before batch lookups
        do {
            try await ensureAuthorization()
        } catch {
            logAuthorizationFailure(error, operation: "prewarm")
            return
        }
        guard isCurrentAccountGeneration(generation) else { return }

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
        ParticipantRollupDependencyTracker.shared.invalidate(email: normalizedEmail)
    }

    /// Invalidates all cached contact data.
    /// Call this if a contact was modified and we don't know which emails changed.
    public func invalidateAllCache() {
        cache.removeAllObjects()
        ParticipantRollupDependencyTracker.shared.invalidateAll()
    }

    // MARK: - Account Lifecycle

    /// Drains direct lookup writers as well as clearing contact memory. A
    /// `lookup` can await avatar storage and then save a Person independently
    /// of PersonCache/ProfilePhotoResolver, so AuthSession must include this
    /// actor in the participant boundary before resetting the store.
    func closeAccountWorkAndClear() async {
        let closingGeneration = accountGeneration
        if acceptsAccountWork {
            acceptsAccountWork = false
            accountGenerationToken.invalidate()
        }
        invalidateAllCache()
        await waitForAccountOperationsToDrain(generation: closingGeneration)
    }

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

    func isCurrentAccountGeneration(
        _ generation: ParticipantCacheAccountGenerationToken
    ) -> Bool {
        acceptsAccountWork
            && generation.value == accountGeneration
            && generation === accountGenerationToken
            && generation.isActive
    }

    private func logAuthorizationFailure(_ error: Error, operation: String) {
        // Not-determined is the normal pre-prompt state on fresh installs and
        // hits every lookup until the deliberate request runs; don't warn-spam.
        if case ContactsError.accessNotDetermined = error {
            Log.debug("Contacts \(operation) skipped: authorization not determined", category: .general)
        } else {
            Log.warning("Contacts authorization failed for \(operation): \(error)", category: .general)
        }
    }
}

// MARK: - Convenience Methods

extension ContactsResolver {

    /// Resolves just the display name for an email, with a safe placeholder fallback.
    public func resolveDisplayName(for email: String) async -> String {
        let match = await lookup(email: email)
        return PersonDisplayNameResolver.participantDisplayName(
            email: email,
            contactDisplayName: match?.displayName,
            headerDisplayName: nil,
            storedDisplayName: nil
        ).name
    }

    /// Resolves just the avatar data for an email.
    public func resolveAvatarData(for email: String) async -> Data? {
        return await lookup(email: email)?.imageData
    }

    /// Batch resolve avatar data for multiple emails.
    /// Much more efficient than individual lookups when prefetching.
    public func resolveAvatarDataBatch(for emails: [String]) async -> [String: Data] {
        guard !emails.isEmpty else { return [:] }
        guard let generation = beginAccountOperation() else { return [:] }
        defer { finishAccountOperation(generation) }

        // Ensure we have authorization
        do {
            try await ensureAuthorization()
        } catch {
            logAuthorizationFailure(error, operation: "batch lookup")
            return [:]
        }
        guard isCurrentAccountGeneration(generation) else { return [:] }

        let normalizedEmails = Set(emails.map { EmailNormalizer.normalize($0) })

        // Uses extension method
        let results = performBatchLookup(for: normalizedEmails)
        return isCurrentAccountGeneration(generation) ? results : [:]
    }
}
