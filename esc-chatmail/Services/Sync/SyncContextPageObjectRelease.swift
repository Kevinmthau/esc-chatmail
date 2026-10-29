import CoreData
import Foundation

/// Turns a saved page's rows back into faults in a long-lived sync context.
///
/// Initial sync and history recovery reuse one context for every listed page.
/// Inserted rows are wired in both directions (`Conversation.messages`,
/// `Message.participants`, `Person.messageParticipations`, `Label.messages`),
/// and the rollup prefetch realizes `conversation.messages` too, so after each
/// save those realized sets form strong cycles and every message of the run
/// stayed resident with its body text, snippet and participants. A
/// since-install re-list held about 1.6 GB at 400k messages and was killed
/// part-way, then restarted from page 1.
///
/// Only the page's own rows are refreshed. `refreshAllObjects()` would also
/// re-fault the system Label and self Person hubs, so the next page's first
/// label or participant write would refire a fault over every member saved so
/// far: quadratic over a large re-list. `reset()` would invalidate objects the
/// persister's per-run caches still hold.
enum SyncContextPageObjectRelease {
    /// The rows a page touched, captured before its save (after the save the
    /// context no longer reports them as inserted or updated). Inserted rows
    /// get their permanent IDs here, so the IDs still resolve after the save.
    struct Capture: Sendable {
        fileprivate let objectIDs: [NSManagedObjectID]

        var count: Int { objectIDs.count }
    }

    /// Call inside the page's save point, after the rollup and before the save.
    static func capture(in context: NSManagedObjectContext) async throws -> Capture {
        try await context.perform {
            var objects: [NSManagedObject] = []
            var seen = Set<ObjectIdentifier>()

            func add(_ object: NSManagedObject) {
                if seen.insert(ObjectIdentifier(object)).inserted {
                    objects.append(object)
                }
            }

            func addMessage(_ message: Message) {
                add(message)
                if !message.hasFault(forRelationshipNamed: "participants") {
                    message.participants?.forEach(add)
                }
                if !message.hasFault(forRelationshipNamed: "attachments") {
                    message.attachments?.forEach(add)
                }
            }

            for object in context.insertedObjects.union(context.updatedObjects) {
                switch object {
                case let message as Message:
                    addMessage(message)
                case let conversation as Conversation:
                    add(conversation)
                    // The rollup realized this set, re-firing earlier pages'
                    // messages; release them with the page that loaded them.
                    if !conversation.hasFault(forRelationshipNamed: "messages") {
                        conversation.messages?.forEach(addMessage)
                    }
                case is MessageParticipant, is Attachment:
                    add(object)
                default:
                    break
                }
            }
            let temporary = objects.filter { $0.objectID.isTemporaryID }
            if !temporary.isEmpty {
                try context.obtainPermanentIDs(for: temporary)
            }
            return Capture(objectIDs: objects.map(\.objectID))
        }
    }

    /// Call only after the page's save succeeded. Never saves, and skips any
    /// row that still has changes, so it can never discard staged state.
    static func release(_ capture: Capture, in context: NSManagedObjectContext) async {
        await context.perform {
            for objectID in capture.objectIDs {
                guard let object = context.registeredObject(for: objectID),
                      !object.isDeleted,
                      !object.isFault,
                      !object.hasChanges else {
                    continue
                }
                context.refresh(object, mergeChanges: false)
            }
        }
    }
}
