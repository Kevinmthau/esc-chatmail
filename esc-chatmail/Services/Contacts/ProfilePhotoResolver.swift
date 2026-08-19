import Foundation
import CoreData
import UIKit

/// Resolves profile photos for email addresses using multiple sources:
/// 1. Local device Contacts
/// 2. Cached results in CoreData Person entities
///
actor ProfilePhotoResolver: MemoryWarningHandler {
    static let shared = ProfilePhotoResolver()

    private struct RequestKey: Hashable, Sendable {
        let accountGeneration: UInt64
        let email: String
    }

    private struct InFlightRequest {
        let id: UUID
        let task: Task<ProfilePhoto?, Never>
    }

    private let contactsResolver: any ContactsResolving
    private let coreDataStack: CoreDataStack
    private let cache: NSCache<NSString, CachedPhoto>
    private let saveAvatar: @Sendable (String, Data) async -> String?
    private let loadAvatar: @Sendable (String) async -> Data?
    private let migrateAvatar: @Sendable (String, String) async -> String?
    private let memoryObserver = MemoryWarningObserver()
    private var inFlightRequests: [RequestKey: InFlightRequest] = [:]
    private var acceptsAccountWork = true
    private var accountGeneration: UInt64 = 0
    private var accountGenerationToken = ParticipantCacheAccountGenerationToken(value: 0)
    private var activeOperationCounts: [UInt64: Int] = [:]
    private var drainWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

    /// The cache and contactsResolver parameters are testing seams (cost-recording
    /// spy, hermetic contacts stub); production code uses `shared`.
    init(
        cache: NSCache<NSString, CachedPhoto> = NSCache(),
        contactsResolver: any ContactsResolving = ContactsResolver.shared,
        coreDataStack: CoreDataStack = .shared,
        saveAvatar: @escaping @Sendable (String, Data) async -> String? = { email, data in
            AvatarStorage.shared.saveAvatar(for: email, imageData: data)
        },
        loadAvatar: @escaping @Sendable (String) async -> Data? = { url in
            AvatarStorage.shared.loadAvatar(from: url)
        },
        migrateAvatar: @escaping @Sendable (String, String) async -> String? = { email, base64URL in
            AvatarStorage.shared.migrateFromBase64(email: email, base64URL: base64URL)
        }
    ) {
        self.cache = cache
        self.contactsResolver = contactsResolver
        self.coreDataStack = coreDataStack
        self.saveAvatar = saveAvatar
        self.loadAvatar = loadAvatar
        self.migrateAvatar = migrateAvatar
        cache.countLimit = CacheConfig.photoCacheSize
        // Set memory limit (assume ~50KB average per photo, allows ~25MB)
        cache.totalCostLimit = 25 * 1024 * 1024

        // Observe memory warnings
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.memoryObserver.start(handler: self)
        }
    }

    // MARK: - MemoryWarningHandler

    func handleMemoryWarning() async {
        clearCache()
    }

    // MARK: - Public API

    /// Resolves a profile photo for an email address
    /// Returns cached result immediately if available, otherwise fetches from sources
    func resolvePhoto(for email: String) async -> ProfilePhoto? {
        guard let generation = beginAccountOperation() else { return nil }
        defer { finishAccountOperation(generation) }

        let normalizedEmail = EmailNormalizer.normalize(email)

        // Check memory cache first
        if let cached = unexpiredCachedPhoto(forNormalizedEmail: normalizedEmail) {
            return cached.photo
        }

        // Include the account generation in the key. If a close is draining
        // while a newer generation reopens, the new caller must never join the
        // old account's email-keyed request.
        let requestKey = RequestKey(
            accountGeneration: generation.value,
            email: normalizedEmail
        )
        let request: InFlightRequest
        if let existing = inFlightRequests[requestKey] {
            request = existing
        } else {
            let id = UUID()
            let task = Task<ProfilePhoto?, Never> { [weak self] in
                guard let self else { return nil }
                return await self.fetchPhoto(
                    for: normalizedEmail,
                    accountGeneration: generation
                )
            }
            request = InFlightRequest(id: id, task: task)
            inFlightRequests[requestKey] = request
        }

        let photo = await request.task.value
        if inFlightRequests[requestKey]?.id == request.id {
            inFlightRequests[requestKey] = nil
        }
        guard isCurrentAccountGeneration(generation) else { return nil }

        // Cache the result (even if nil, to avoid repeated lookups).
        // Cost is the compressed data size; nil negative-cache entries cost ~0.
        let cached = CachedPhoto(photo: photo, timestamp: Date())
        cache.setObject(cached, forKey: normalizedEmail as NSString, cost: cached.estimatedCacheCost)

        return photo
    }

    /// Batch resolve photos for multiple emails
    func resolvePhotos(for emails: [String]) async -> [String: ProfilePhoto] {
        guard let generation = beginAccountOperation() else { return [:] }
        defer { finishAccountOperation(generation) }

        var results: [String: ProfilePhoto] = [:]

        await withTaskGroup(of: (String, ProfilePhoto?).self) { group in
            for email in emails {
                group.addTask {
                    let photo = await self.resolvePhoto(for: email)
                    return (email, photo)
                }
            }

            for await (email, photo) in group {
                if let photo = photo {
                    results[EmailNormalizer.normalize(email)] = photo
                }
            }
        }

        return isCurrentAccountGeneration(generation) ? results : [:]
    }

    /// Clears the memory cache
    func clearCache() {
        cache.removeAllObjects()
    }

    /// Prefetch photos for multiple emails without blocking.
    /// Uses batch contact lookup for efficiency, then caches results.
    /// Emails the memory cache already resolves are skipped up front, so
    /// recurring callers (chat-list reloads, sync batches) do not re-run the
    /// Contacts enumeration or rewrite avatars for warm entries.
    func prefetchPhotos(for emails: [String]) async {
        guard !emails.isEmpty else { return }
        guard let generation = beginAccountOperation() else { return }
        defer { finishAccountOperation(generation) }

        // The same gate resolvePhoto(for:) applies: an unexpired memory-cache
        // entry — photo or negative — answers without any lookup, so
        // prefetching it would only repeat the batch lookup and avatar write.
        let uncachedEmails = emails.filter { email in
            unexpiredCachedPhoto(forNormalizedEmail: EmailNormalizer.normalize(email)) == nil
        }
        guard !uncachedEmails.isEmpty else { return }

        // The caller may already be superseded (the chat list replaces its
        // detached prefetch task on every reload); the Contacts enumeration
        // is the expensive part, so never start it for a cancelled task.
        guard !Task.isCancelled else { return }

        // First, batch lookup from Contacts for efficiency
        let contactPhotos = await contactsResolver.resolveAvatarDataBatch(for: uncachedEmails)
        guard isCurrentAccountGeneration(generation) else { return }

        // Save found photos to cache and storage
        for (normalizedEmail, imageData) in contactPhotos {
            guard isCurrentAccountGeneration(generation) else { return }
            // Save to file storage
            if let fileURL = await saveAvatar(normalizedEmail, imageData) {
                guard isCurrentAccountGeneration(generation) else { return }
                await savePhotoURLToCache(
                    email: normalizedEmail,
                    url: fileURL,
                    accountGeneration: generation
                )
            }
            guard isCurrentAccountGeneration(generation) else { return }
            // Add to memory cache
            let photo = ProfilePhoto(source: .contacts, imageData: imageData, url: nil)
            let cached = CachedPhoto(photo: photo, timestamp: Date())
            cache.setObject(cached, forKey: normalizedEmail as NSString, cost: cached.estimatedCacheCost)
        }

        // For emails not found in contacts, check cache individually
        let foundEmails = Set(contactPhotos.keys)
        let remainingEmails = uncachedEmails
            .map { EmailNormalizer.normalize($0) }
            .filter { !foundEmails.contains($0) }

        // Resolve remaining emails with structured concurrency
        await withTaskGroup(of: Void.self) { group in
            for email in remainingEmails {
                group.addTask {
                    _ = await self.resolvePhoto(for: email)
                }
            }
        }
    }

    // MARK: - Private Methods

    /// Memory-cache read shared by `resolvePhoto(for:)` and the
    /// `prefetchPhotos(for:)` gate: returns the unexpired cached entry
    /// (photo or negative) for an already-normalized email, evicting an
    /// expired entry so both callers agree the email needs re-resolving.
    private func unexpiredCachedPhoto(forNormalizedEmail normalizedEmail: String) -> CachedPhoto? {
        if let cached = cache.object(forKey: normalizedEmail as NSString) {
            if !cached.isExpired {
                return cached
            }
            cache.removeObject(forKey: normalizedEmail as NSString)
        }
        return nil
    }

    private func fetchPhoto(
        for email: String,
        accountGeneration: ParticipantCacheAccountGenerationToken
    ) async -> ProfilePhoto? {
        guard isCurrentAccountGeneration(accountGeneration), !Task.isCancelled else { return nil }

        // 1. Check CoreData Person cache first
        if let cachedURL = await getCachedPhotoURL(
            for: email,
            accountGeneration: accountGeneration
        ) {
            guard isCurrentAccountGeneration(accountGeneration), !Task.isCancelled else { return nil }
            // Handle file:// URLs (new format)
            if cachedURL.hasPrefix("file://") {
                if let data = await loadAvatar(cachedURL),
                   isCurrentAccountGeneration(accountGeneration),
                   !Task.isCancelled {
                    return ProfilePhoto(source: .cached, imageData: data, url: nil)
                }
            }
            // Handle legacy data:// URLs (base64)
            else if cachedURL.hasPrefix("data:image") {
                if let data = dataFromBase64URL(cachedURL) {
                    // Keep migration in the tracked request. A detached task
                    // could outlive account teardown and write into the next
                    // account's Person store after AuthSession resets it.
                    if let fileURL = await migrateAvatar(email, cachedURL),
                       isCurrentAccountGeneration(accountGeneration),
                       !Task.isCancelled {
                        await savePhotoURLToCache(
                            email: email,
                            url: fileURL,
                            replacingURL: cachedURL,
                            accountGeneration: accountGeneration
                        )
                    }
                    guard isCurrentAccountGeneration(accountGeneration),
                          !Task.isCancelled else { return nil }
                    return ProfilePhoto(source: .cached, imageData: data, url: nil)
                }
            } else if !cachedURL.isEmpty {
                guard isCurrentAccountGeneration(accountGeneration),
                      !Task.isCancelled else { return nil }
                return ProfilePhoto(source: .cached, imageData: nil, url: cachedURL)
            }
        }

        // 2. Try local Contacts
        if let contactPhoto = await fetchFromContacts(email: email) {
            guard isCurrentAccountGeneration(accountGeneration),
                  !Task.isCancelled else { return nil }
            // Save to CoreData for future use
            await savePhotoToCache(
                email: email,
                imageData: contactPhoto,
                accountGeneration: accountGeneration
            )
            guard isCurrentAccountGeneration(accountGeneration),
                  !Task.isCancelled else { return nil }
            return ProfilePhoto(source: .contacts, imageData: contactPhoto, url: nil)
        }

        return nil
    }

    private func fetchFromContacts(email: String) async -> Data? {
        return await contactsResolver.resolveAvatarData(for: email)
    }

    private func getCachedPhotoURL(
        for email: String,
        accountGeneration: ParticipantCacheAccountGenerationToken
    ) async -> String? {
        guard isCurrentAccountGeneration(accountGeneration), !Task.isCancelled else { return nil }
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            guard accountGeneration.isActive else { return nil }
            let request = Person.fetchRequest()
            request.predicate = NSPredicate(format: "email == %@", email)
            request.fetchLimit = 1

            if let person = try? context.fetch(request).first,
               let avatarURL = person.avatarURL,
               !avatarURL.isEmpty {
                return avatarURL
            }
            return nil
        }
    }

    private func savePhotoToCache(
        email: String,
        imageData: Data,
        accountGeneration: ParticipantCacheAccountGenerationToken
    ) async {
        guard isCurrentAccountGeneration(accountGeneration), !Task.isCancelled else { return }
        // Save to file storage instead of base64 to avoid database bloat
        if let fileURL = await saveAvatar(email, imageData),
           isCurrentAccountGeneration(accountGeneration),
           !Task.isCancelled {
            await savePhotoURLToCache(
                email: email,
                url: fileURL,
                accountGeneration: accountGeneration
            )
        }
    }

    private func savePhotoURLToCache(
        email: String,
        url: String,
        replacingURL expectedURL: String? = nil,
        accountGeneration: ParticipantCacheAccountGenerationToken
    ) async {
        guard isCurrentAccountGeneration(accountGeneration), !Task.isCancelled else { return }
        // Use background context to avoid blocking main thread
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            _ = accountGeneration.withActiveGeneration {
                let request = Person.fetchRequest()
                request.predicate = NSPredicate(format: "email == %@", email)
                request.fetchLimit = 1

                if let person = try? context.fetch(request).first {
                    // A legacy data URL is replaced only if it is still the
                    // value this request migrated. Other callers must not
                    // overwrite a newer nonempty avatar URL.
                    if person.avatarURL == nil
                        || person.avatarURL?.isEmpty == true
                        || person.avatarURL == expectedURL {
                        person.avatarURL = url
                        context.saveOrLog(operation: "update person avatar URL")
                    }
                }
            }
        }
    }

    // MARK: - Account Lifecycle

    /// Invalidates old results synchronously, cancels their request tasks, and
    /// drains every old-generation caller before AuthSession resets Core Data.
    func closeAccountWorkAndClear() async {
        let closingGeneration = accountGeneration
        if acceptsAccountWork {
            acceptsAccountWork = false
            accountGenerationToken.invalidate()
        }
        cache.removeAllObjects()

        let oldRequests = inFlightRequests.filter {
            $0.key.accountGeneration == closingGeneration
        }
        oldRequests.values.forEach { $0.task.cancel() }

        await waitForAccountOperationsToDrain(generation: closingGeneration)
        for (key, request) in oldRequests
        where inFlightRequests[key]?.id == request.id {
            inFlightRequests[key] = nil
        }
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

    private func isCurrentAccountGeneration(
        _ generation: ParticipantCacheAccountGenerationToken
    ) -> Bool {
        acceptsAccountWork
            && generation.value == accountGeneration
            && generation === accountGenerationToken
            && generation.isActive
    }

    private func dataFromBase64URL(_ dataURL: String) -> Data? {
        // Parse data URL: data:image/jpeg;base64,<base64data>
        guard let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let base64String = String(dataURL[dataURL.index(after: commaIndex)...])
        return Data(base64Encoded: base64String)
    }
}

// MARK: - Supporting Types

struct ProfilePhoto {
    enum Source {
        case contacts
        case cached
    }

    let source: Source
    let imageData: Data?
    let url: String?

    /// Returns UIImage from either imageData or by loading from URL
    func loadImage() async -> UIImage? {
        if let data = imageData {
            return UIImage(data: data)
        }

        if let urlString = url {
            return await RemoteImageFetcher.shared.image(from: urlString)
        }

        return nil
    }
}

/// Internal (not private) and NSObject-backed so tests can construct the
/// resolver's cache type and subclass NSCache with it (ObjC representability).
final class CachedPhoto: NSObject {
    let photo: ProfilePhoto?
    let timestamp: Date

    init(photo: ProfilePhoto?, timestamp: Date) {
        self.photo = photo
        self.timestamp = timestamp
    }

    var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > CacheConfig.photoCacheTTL
    }

    /// NSCache cost: size of the compressed photo bytes. URL-only and nil
    /// (negative-cache) entries are effectively free.
    var estimatedCacheCost: Int {
        photo?.imageData?.count ?? 0
    }
}
