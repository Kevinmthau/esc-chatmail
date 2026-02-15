import Foundation
import CoreData
import Combine

/// Coordinates cache invalidation across multiple caches when Core Data changes.
///
/// Listens for NSManagedObjectContextDidSave notifications and invalidates
/// relevant caches to prevent stale data.
///
/// ## Usage
/// Initialize once at app startup:
/// ```swift
/// CacheCoordinator.shared.start()
/// ```
///
/// The coordinator automatically invalidates:
/// - ConversationCache when Conversation entities are updated/deleted
/// - PersonCache when Person entities are updated/deleted
/// - ProcessedTextCache when Message entities are deleted
@MainActor
final class CacheCoordinator {
    static let shared = CacheCoordinator()

    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false

    private init() {}

    /// Starts listening for Core Data changes. Call once at app startup.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleContextDidSave(notification)
            }
            .store(in: &cancellables)

        Log.debug("CacheCoordinator started", category: .coreData)
    }

    /// Stops listening for Core Data changes.
    func stop() {
        cancellables.removeAll()
        isStarted = false
    }

    private func handleContextDidSave(_ notification: Notification) {
        let updated = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
        let deleted = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []

        var conversationIdsToInvalidate: Set<String> = []
        var personEmailsToInvalidate: Set<String> = []
        var messageIdsToInvalidate: Set<String> = []

        // Process updated and deleted objects
        for object in updated.union(deleted) {
            if let conversation = object as? Conversation {
                // Deleted objects can fault/lose property values; accessing non-optional Core Data
                // properties directly may trap. Use KVC to safely extract the UUID string.
                if let id = conversation.value(forKey: "id") as? NSUUID {
                    conversationIdsToInvalidate.insert(id.uuidString)
                } else if let id = conversation.value(forKey: "id") as? UUID {
                    conversationIdsToInvalidate.insert(id.uuidString)
                } else {
                    Log.warning("Conversation missing id during cache invalidation; clearing ConversationCache", category: .coreData)
                    ConversationCache.shared.clear()
                }
            } else if let person = object as? Person {
                personEmailsToInvalidate.insert(person.email)
            } else if deleted.contains(object), let message = object as? Message {
                messageIdsToInvalidate.insert(message.id)
            }
        }

        // Invalidate conversation cache
        if !conversationIdsToInvalidate.isEmpty {
            for conversationId in conversationIdsToInvalidate {
                ConversationCache.shared.invalidate(conversationId)
            }
            Log.debug("Invalidated \(conversationIdsToInvalidate.count) conversation cache entries", category: .coreData)
        }

        // Invalidate person cache
        // Note: Fire-and-forget is acceptable here - caches are in-memory only and
        // will be empty on next app launch. The async pattern is required because
        // PersonCache is an actor.
        if !personEmailsToInvalidate.isEmpty {
            let emails = personEmailsToInvalidate  // Capture for async closure
            Task {
                for email in emails {
                    await PersonCache.shared.invalidateEntry(for: email)
                }
            }
            Log.debug("Queued invalidation for \(personEmailsToInvalidate.count) person cache entries", category: .coreData)
        }

        // Invalidate processed text cache for deleted messages
        // Note: Same fire-and-forget rationale as person cache above
        if !messageIdsToInvalidate.isEmpty {
            let messageIds = messageIdsToInvalidate  // Capture for async closure
            Task {
                for messageId in messageIds {
                    await ProcessedTextCache.shared.invalidate(messageId: messageId)
                    HTMLContentLoader.shared.invalidate(messageId: messageId)
                }
            }
            Log.debug("Queued invalidation for \(messageIdsToInvalidate.count) processed text cache entries", category: .coreData)
        }
    }
}
