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

    private struct CacheInvalidationPlan {
        var conversationIdsToInvalidate: Set<String> = []
        var personEmailsToInvalidate: Set<String> = []
        var messageIdsToInvalidate: Set<String> = []
        var shouldClearConversationCache = false
        var shouldClearPersonCache = false
    }

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
        guard let sourceContext = notification.object as? NSManagedObjectContext else { return }

        let updatedObjects = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
        let deletedObjects = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []
        let updatedObjectIDs = (notification.userInfo?[NSUpdatedObjectIDsKey] as? Set<NSManagedObjectID>) ??
            Set(updatedObjects.map(\.objectID))
        let deletedObjectIDs = (notification.userInfo?[NSDeletedObjectIDsKey] as? Set<NSManagedObjectID>) ??
            Set(deletedObjects.map(\.objectID))

        guard !updatedObjectIDs.isEmpty || !deletedObjectIDs.isEmpty else { return }

        let plan = sourceContext.performAndWait { () -> CacheInvalidationPlan in
            var localPlan = CacheInvalidationPlan()

            // Access managed object values on the source context's queue to avoid cross-queue reads.
            for objectID in updatedObjectIDs.union(deletedObjectIDs) {
                let object = sourceContext.object(with: objectID)
                if let conversation = object as? Conversation {
                    // Deleted objects can fault/lose property values; use KVC defensively.
                    if let id = conversation.value(forKey: "id") as? NSUUID {
                        localPlan.conversationIdsToInvalidate.insert(id.uuidString)
                    } else if let id = conversation.value(forKey: "id") as? UUID {
                        localPlan.conversationIdsToInvalidate.insert(id.uuidString)
                    } else {
                        localPlan.shouldClearConversationCache = true
                    }
                    continue
                }

                if let person = object as? Person {
                    if let email = person.value(forKey: "email") as? String, !email.isEmpty {
                        localPlan.personEmailsToInvalidate.insert(email)
                    } else {
                        localPlan.shouldClearPersonCache = true
                    }
                    continue
                }

                if deletedObjectIDs.contains(objectID),
                   let message = object as? Message,
                   let messageId = message.value(forKey: "id") as? String,
                   !messageId.isEmpty {
                    localPlan.messageIdsToInvalidate.insert(messageId)
                }
            }

            return localPlan
        }

        applyInvalidationPlan(plan)
    }

    private func applyInvalidationPlan(_ plan: CacheInvalidationPlan) {
        // Invalidate conversation cache
        if plan.shouldClearConversationCache {
            Log.warning("Conversation id missing during cache invalidation; clearing ConversationCache", category: .coreData)
            ConversationCache.shared.clear()
        } else if !plan.conversationIdsToInvalidate.isEmpty {
            for conversationId in plan.conversationIdsToInvalidate {
                ConversationCache.shared.invalidate(conversationId)
            }
            Log.debug("Invalidated \(plan.conversationIdsToInvalidate.count) conversation cache entries", category: .coreData)
        }

        // Invalidate person cache
        // Note: Fire-and-forget is acceptable here - caches are in-memory only and
        // will be empty on next app launch. The async pattern is required because
        // PersonCache is an actor.
        if plan.shouldClearPersonCache {
            Task {
                await PersonCache.shared.clearCache()
            }
            Log.warning("Person email missing during cache invalidation; queued full PersonCache clear", category: .coreData)
        } else if !plan.personEmailsToInvalidate.isEmpty {
            let emails = plan.personEmailsToInvalidate  // Capture for async closure
            Task {
                for email in emails {
                    await PersonCache.shared.invalidateEntry(for: email)
                }
            }
            Log.debug("Queued invalidation for \(plan.personEmailsToInvalidate.count) person cache entries", category: .coreData)
        }

        // Invalidate processed text cache for deleted messages
        // Note: Same fire-and-forget rationale as person cache above
        if !plan.messageIdsToInvalidate.isEmpty {
            let messageIds = plan.messageIdsToInvalidate  // Capture for async closure
            Task {
                for messageId in messageIds {
                    await ProcessedTextCache.shared.invalidate(messageId: messageId)
                    HTMLContentLoader.shared.invalidate(messageId: messageId)
                }
            }
            Log.debug("Queued invalidation for \(plan.messageIdsToInvalidate.count) processed text cache entries", category: .coreData)
        }
    }
}
