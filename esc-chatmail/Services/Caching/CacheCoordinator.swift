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

    struct CacheInvalidationPlan: Sendable {
        struct DeletedHTMLArtifact: Sendable, Hashable {
            let messageId: String
            let bodyStorageURI: String?
        }

        var conversationIdsToInvalidate: Set<String> = []
        var personEmailsToInvalidate: Set<String> = []
        var messageIdsToInvalidate: Set<String> = []
        var deletedHTMLArtifacts: Set<DeletedHTMLArtifact> = []
        var attachmentPathsToDelete: Set<String> = []
        var attachmentIdsToInvalidate: Set<String> = []
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

        sourceContext.perform { [weak self] in
            let localPlan = CacheCoordinator.computeInvalidationPlan(
                updatedObjectIDs: updatedObjectIDs,
                deletedObjectIDs: deletedObjectIDs,
                in: sourceContext
            )

            Task { @MainActor [weak self] in
                self?.applyInvalidationPlan(localPlan)
            }
        }
    }

    /// Computes the cache-invalidation plan for a set of changed Core Data object IDs.
    ///
    /// Pure and side-effect-free: it inspects the changed managed objects and
    /// decides which caches need invalidating, returning the decision as a
    /// `CacheInvalidationPlan`. It performs no invalidation itself — that is the
    /// job of `applyInvalidationPlan(_:)`.
    ///
    /// Declared `nonisolated` so it can run on the source context's queue (where
    /// these managed objects are safe to read), and so the invalidation contract
    /// can be unit-tested directly without driving the global
    /// `NSManagedObjectContextDidSave` notification and async-apply path.
    ///
    /// - Note: Reads managed-object values via KVC defensively because deleted
    ///   objects can fault and lose their property values.
    nonisolated static func computeInvalidationPlan(
        updatedObjectIDs: Set<NSManagedObjectID>,
        deletedObjectIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) -> CacheInvalidationPlan {
        var plan = CacheInvalidationPlan()

        // Access managed object values on the context's queue to avoid cross-queue reads.
        for objectID in updatedObjectIDs.union(deletedObjectIDs) {
            let object = context.object(with: objectID)
            if let conversation = object as? Conversation {
                // Deleted objects can fault/lose property values; use KVC defensively.
                if let id = conversation.value(forKey: "id") as? NSUUID {
                    plan.conversationIdsToInvalidate.insert(id.uuidString)
                } else if let id = conversation.value(forKey: "id") as? UUID {
                    plan.conversationIdsToInvalidate.insert(id.uuidString)
                } else {
                    plan.shouldClearConversationCache = true
                }
                continue
            }

            if let person = object as? Person {
                if let email = person.value(forKey: "email") as? String, !email.isEmpty {
                    plan.personEmailsToInvalidate.insert(email)
                } else {
                    plan.shouldClearPersonCache = true
                }
                continue
            }

            if deletedObjectIDs.contains(objectID),
               let message = object as? Message,
               let messageId = message.value(forKey: "id") as? String,
               !messageId.isEmpty {
                plan.messageIdsToInvalidate.insert(messageId)
                plan.deletedHTMLArtifacts.insert(
                    CacheInvalidationPlan.DeletedHTMLArtifact(
                        messageId: messageId,
                        bodyStorageURI: message.value(forKey: "bodyStorageURI") as? String
                    )
                )

                if let attachments = message.value(forKey: "attachments") as? Set<NSManagedObject> {
                    for attachment in attachments {
                        if let localURL = attachment.value(forKey: "localURL") as? String, !localURL.isEmpty {
                            plan.attachmentPathsToDelete.insert(localURL)
                        }
                        if let previewURL = attachment.value(forKey: "previewURL") as? String, !previewURL.isEmpty {
                            plan.attachmentPathsToDelete.insert(previewURL)
                        }
                        if let attachmentId = attachment.value(forKey: "id") as? String, !attachmentId.isEmpty {
                            plan.attachmentIdsToInvalidate.insert(attachmentId)
                        }
                    }
                }
                continue
            }

            if deletedObjectIDs.contains(objectID),
               let attachment = object as? Attachment {
                if let localURL = attachment.value(forKey: "localURL") as? String, !localURL.isEmpty {
                    plan.attachmentPathsToDelete.insert(localURL)
                }
                if let previewURL = attachment.value(forKey: "previewURL") as? String, !previewURL.isEmpty {
                    plan.attachmentPathsToDelete.insert(previewURL)
                }
                if let attachmentId = attachment.value(forKey: "id") as? String, !attachmentId.isEmpty {
                    plan.attachmentIdsToInvalidate.insert(attachmentId)
                }
            }
        }

        return plan
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

        let shouldProcessDeletedArtifacts =
            !plan.messageIdsToInvalidate.isEmpty ||
            !plan.deletedHTMLArtifacts.isEmpty ||
            !plan.attachmentPathsToDelete.isEmpty ||
            !plan.attachmentIdsToInvalidate.isEmpty

        // Invalidate processed text cache and reclaim deleted message/attachment artifacts.
        // Note: Same fire-and-forget rationale as person cache above.
        if shouldProcessDeletedArtifacts {
            let messageIds = plan.messageIdsToInvalidate
            let deletedHTMLArtifacts = plan.deletedHTMLArtifacts
            let attachmentPaths = plan.attachmentPathsToDelete
            let attachmentIds = plan.attachmentIdsToInvalidate

            Task {
                for messageId in messageIds {
                    await ProcessedTextCache.shared.invalidate(messageId: messageId)
                    HTMLContentLoader.shared.invalidate(messageId: messageId)
                }

                for artifact in deletedHTMLArtifacts {
                    HTMLContentHandler.shared.deleteHTML(
                        for: artifact.messageId,
                        bodyStorageURI: artifact.bodyStorageURI
                    )
                }

                for relativePath in attachmentPaths {
                    AttachmentPaths.deleteFile(at: relativePath)
                }

                for attachmentId in attachmentIds {
                    await AttachmentCacheActor.shared.removeFromCache(attachmentId)
                }
            }
        }

        if !plan.messageIdsToInvalidate.isEmpty {
            Log.debug("Queued invalidation for \(plan.messageIdsToInvalidate.count) processed text cache entries", category: .coreData)
        }

        if !plan.attachmentPathsToDelete.isEmpty || !plan.attachmentIdsToInvalidate.isEmpty {
            Log.debug(
                "Queued cleanup for \(plan.attachmentPathsToDelete.count) attachment files and \(plan.attachmentIdsToInvalidate.count) attachment cache entries",
                category: .coreData
            )
        }
    }
}
