import Foundation
import CoreData
import UIKit

/// Resolves profile photos for email addresses using multiple sources:
/// 1. Local device Contacts
/// 2. Cached results in CoreData Person entities
///
/// Uses InFlightRequestManager for request deduplication to prevent duplicate fetches
actor ProfilePhotoResolver: MemoryWarningHandler {
    static let shared = ProfilePhotoResolver()

    private let contactsResolver = ContactsResolver.shared
    private let coreDataStack = CoreDataStack.shared
    private let cache = NSCache<NSString, CachedPhoto>()
    private let requestManager = InFlightRequestManager<String, ProfilePhoto>()
    private let memoryObserver = MemoryWarningObserver()

    private init() {
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
        let normalizedEmail = EmailNormalizer.normalize(email)

        // Check memory cache first
        if let cached = cache.object(forKey: normalizedEmail as NSString) {
            if !cached.isExpired {
                return cached.photo
            }
            cache.removeObject(forKey: normalizedEmail as NSString)
        }

        // Use request manager for deduplication
        let photo = await requestManager.deduplicated(key: normalizedEmail) { [self] in
            await fetchPhoto(for: normalizedEmail)
        }

        // Cache the result (even if nil, to avoid repeated lookups)
        let cached = CachedPhoto(photo: photo, timestamp: Date())
        cache.setObject(cached, forKey: normalizedEmail as NSString)

        return photo
    }

    /// Batch resolve photos for multiple emails
    func resolvePhotos(for emails: [String]) async -> [String: ProfilePhoto] {
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

        return results
    }

    /// Clears the memory cache
    func clearCache() {
        cache.removeAllObjects()
    }

    /// Prefetch photos for multiple emails without blocking
    /// Uses batch contact lookup for efficiency, then caches results
    func prefetchPhotos(for emails: [String]) async {
        guard !emails.isEmpty else { return }

        // First, batch lookup from Contacts for efficiency
        let contactPhotos = await contactsResolver.resolveAvatarDataBatch(for: emails)

        // Save found photos to cache and storage
        for (normalizedEmail, imageData) in contactPhotos {
            // Save to file storage
            if let fileURL = await AvatarStorage.shared.saveAvatar(for: normalizedEmail, imageData: imageData) {
                await savePhotoURLToCache(email: normalizedEmail, url: fileURL)
            }
            // Add to memory cache
            let photo = ProfilePhoto(source: .contacts, imageData: imageData, url: nil)
            let cached = CachedPhoto(photo: photo, timestamp: Date())
            cache.setObject(cached, forKey: normalizedEmail as NSString)
        }

        // For emails not found in contacts, check cache individually
        let foundEmails = Set(contactPhotos.keys)
        let remainingEmails = emails
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

    private func fetchPhoto(for email: String) async -> ProfilePhoto? {
        // 1. Check CoreData Person cache first
        if let cachedURL = await getCachedPhotoURL(for: email) {
            // Handle file:// URLs (new format)
            if cachedURL.hasPrefix("file://") {
                if let data = await AvatarStorage.shared.loadAvatar(from: cachedURL) {
                    return ProfilePhoto(source: .cached, imageData: data, url: nil)
                }
            }
            // Handle legacy data:// URLs (base64)
            else if cachedURL.hasPrefix("data:image") {
                if let data = dataFromBase64URL(cachedURL) {
                    // Migrate to file storage in background
                    Task.detached(priority: .utility) {
                        if let fileURL = await AvatarStorage.shared.migrateFromBase64(email: email, base64URL: cachedURL) {
                            await self.savePhotoURLToCache(email: email, url: fileURL)
                        }
                    }
                    return ProfilePhoto(source: .cached, imageData: data, url: nil)
                }
            } else if !cachedURL.isEmpty {
                return ProfilePhoto(source: .cached, imageData: nil, url: cachedURL)
            }
        }

        // 2. Try local Contacts
        if let contactPhoto = await fetchFromContacts(email: email) {
            // Save to CoreData for future use
            await savePhotoToCache(email: email, imageData: contactPhoto)
            return ProfilePhoto(source: .contacts, imageData: contactPhoto, url: nil)
        }

        return nil
    }

    private func fetchFromContacts(email: String) async -> Data? {
        return await contactsResolver.resolveAvatarData(for: email)
    }

    private func getCachedPhotoURL(for email: String) async -> String? {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
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

    private func savePhotoToCache(email: String, imageData: Data) async {
        // Save to file storage instead of base64 to avoid database bloat
        if let fileURL = await AvatarStorage.shared.saveAvatar(for: email, imageData: imageData) {
            await savePhotoURLToCache(email: email, url: fileURL)
        }
    }

    private func savePhotoURLToCache(email: String, url: String) async {
        // Use background context to avoid blocking main thread
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            let request = Person.fetchRequest()
            request.predicate = NSPredicate(format: "email == %@", email)
            request.fetchLimit = 1

            if let person = try? context.fetch(request).first {
                // Only update if not already set
                if person.avatarURL == nil || person.avatarURL?.isEmpty == true {
                    person.avatarURL = url
                    context.saveOrLog(operation: "update person avatar URL")
                }
            }
        }
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

        if let urlString = url, let url = URL(string: urlString) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                return UIImage(data: data)
            } catch {
                Log.debug("Failed to load image from URL: \(error)", category: .general)
            }
        }

        return nil
    }
}

private class CachedPhoto {
    let photo: ProfilePhoto?
    let timestamp: Date

    init(photo: ProfilePhoto?, timestamp: Date) {
        self.photo = photo
        self.timestamp = timestamp
    }

    var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > CacheConfig.photoCacheTTL
    }
}

