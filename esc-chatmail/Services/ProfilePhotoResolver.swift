import Foundation
import CoreData
import UIKit

/// Resolves profile photos for email addresses using multiple sources:
/// 1. Local device Contacts
/// 2. Google People API (for Gmail users you've interacted with)
/// 3. Cached results in CoreData Person entities
actor ProfilePhotoResolver {
    static let shared = ProfilePhotoResolver()

    private let contactsResolver = ContactsResolver.shared
    private let coreDataStack = CoreDataStack.shared
    private let cache = NSCache<NSString, CachedPhoto>()
    private var inFlightRequests: [String: Task<ProfilePhoto?, Never>] = [:]

    /// Queue for People API requests with priority and limit
    private var apiQueue: [String] = []
    private var activeAPIRequests = 0
    private let maxConcurrentAPIRequests = 2
    private let maxQueuedAPIRequests = 10  // Drop requests beyond this to avoid memory bloat

    /// Track emails that failed API lookup to avoid retrying
    private var failedLookups: Set<String> = []

    /// Whether People API lookups are enabled (disabled during initial sync)
    private var peopleAPIEnabled = false

    /// Track when the app started to defer API calls
    private let startTime = Date()

    private init() {
        cache.countLimit = 200

        // Enable People API after a delay to let initial sync complete
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            await enablePeopleAPI()
        }
    }

    /// Enable People API lookups (call after initial sync completes)
    func enablePeopleAPI() {
        peopleAPIEnabled = true
    }

    /// Disable People API lookups (call during heavy sync operations)
    func disablePeopleAPI() {
        peopleAPIEnabled = false
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

        // Check if there's already a request in flight for this email
        if let existingTask = inFlightRequests[normalizedEmail] {
            return await existingTask.value
        }

        // Create a new task for this request
        let task = Task<ProfilePhoto?, Never> {
            let photo = await fetchPhoto(for: normalizedEmail)

            // Cache the result (even if nil, to avoid repeated lookups)
            let cached = CachedPhoto(photo: photo, timestamp: Date())
            cache.setObject(cached, forKey: normalizedEmail as NSString)

            // Remove from in-flight
            inFlightRequests.removeValue(forKey: normalizedEmail)

            return photo
        }

        inFlightRequests[normalizedEmail] = task
        return await task.value
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

    // MARK: - Private Methods

    private func fetchPhoto(for email: String) async -> ProfilePhoto? {
        // 1. Check CoreData Person cache first
        if let cachedURL = await getCachedPhotoURL(for: email) {
            // Handle file:// URLs (new format)
            if cachedURL.hasPrefix("file://") {
                if let data = AvatarStorage.shared.loadAvatar(from: cachedURL) {
                    return ProfilePhoto(source: .cached, imageData: data, url: nil)
                }
            }
            // Handle legacy data:// URLs (base64)
            else if cachedURL.hasPrefix("data:image") {
                if let data = dataFromBase64URL(cachedURL) {
                    // Migrate to file storage in background
                    Task.detached(priority: .utility) {
                        if let fileURL = AvatarStorage.shared.migrateFromBase64(email: email, base64URL: cachedURL) {
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

        // 3. Try Google People API
        if let googlePhotoURL = await fetchFromGooglePeopleAPI(email: email) {
            // Save URL to CoreData
            await savePhotoURLToCache(email: email, url: googlePhotoURL)
            return ProfilePhoto(source: .google, imageData: nil, url: googlePhotoURL)
        }

        return nil
    }

    private func fetchFromContacts(email: String) async -> Data? {
        return await contactsResolver.resolveAvatarData(for: email)
    }

    private func fetchFromGooglePeopleAPI(email: String) async -> String? {
        // Skip if People API is disabled (during initial sync)
        guard peopleAPIEnabled else {
            return nil
        }

        // Skip if we already know this email failed
        if failedLookups.contains(email) {
            return nil
        }

        // Check if queue is full - drop request to avoid memory bloat
        if apiQueue.count >= maxQueuedAPIRequests {
            return nil
        }

        // Check if already queued
        if apiQueue.contains(email) {
            return nil
        }

        // Add to queue
        apiQueue.append(email)

        // Wait for our turn (bounded queue prevents memory bloat)
        while apiQueue.first != email || activeAPIRequests >= maxConcurrentAPIRequests {
            // Yield to avoid busy waiting
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

            // Check if we got removed from queue (cleanup)
            if !apiQueue.contains(email) {
                return nil
            }
        }

        // Our turn - execute the request
        activeAPIRequests += 1
        defer {
            activeAPIRequests -= 1
            apiQueue.removeAll { $0 == email }
        }

        do {
            // Get API client reference on main actor (quick operation)
            let apiClient = await MainActor.run { GmailAPIClient.shared }
            // The actual network call is nonisolated and won't block main thread
            let result = try await apiClient.searchPeopleByEmail(email: email)

            // Find photo URL from result
            if let photoURL = result.photoURL {
                return photoURL
            }
        } catch {
            // Track failure to avoid retrying this session
            failedLookups.insert(email)
        }

        return nil
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
        if let fileURL = AvatarStorage.shared.saveAvatar(for: email, imageData: imageData) {
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
                    try? context.save()
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
        case google
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

    // Cache entries expire after 1 hour
    private let expirationInterval: TimeInterval = 3600

    init(photo: ProfilePhoto?, timestamp: Date) {
        self.photo = photo
        self.timestamp = timestamp
    }

    var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > expirationInterval
    }
}

