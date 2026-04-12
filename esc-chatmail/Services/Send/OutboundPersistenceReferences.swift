import Foundation
import CoreData

struct ConversationReference: Hashable, Sendable {
    fileprivate let persistentStoreURI: URL

    init(objectID: NSManagedObjectID) {
        self.persistentStoreURI = objectID.uriRepresentation()
    }

    init(persistentStoreURI: URL) {
        self.persistentStoreURI = persistentStoreURI
    }
}

enum OptimisticConversationReference: Equatable, Sendable {
    case existingConversation(ConversationReference)
    case participantHash(String)

    var existingConversationReference: ConversationReference? {
        guard case .existingConversation(let conversationReference) = self else {
            return nil
        }

        return conversationReference
    }

    var participantHashValue: String? {
        guard case .participantHash(let participantHash) = self else {
            return nil
        }

        return participantHash
    }
}

struct LocalAttachmentReference: Hashable, Sendable {
    fileprivate let persistentStoreURI: URL

    init(objectID: NSManagedObjectID) {
        self.persistentStoreURI = objectID.uriRepresentation()
    }

    init(persistentStoreURI: URL) {
        self.persistentStoreURI = persistentStoreURI
    }
}

extension ConversationReference {
    @MainActor
    func resolveObjectID(in context: NSManagedObjectContext) -> NSManagedObjectID? {
        resolveManagedObjectID(for: persistentStoreURI, in: context)
    }
}

extension LocalAttachmentReference {
    @MainActor
    func resolveObjectID(in context: NSManagedObjectContext) -> NSManagedObjectID? {
        resolveManagedObjectID(for: persistentStoreURI, in: context)
    }
}

@MainActor
private func resolveManagedObjectID(
    for persistentStoreURI: URL,
    in context: NSManagedObjectContext
) -> NSManagedObjectID? {
    guard let coordinator = context.persistentStoreCoordinator else {
        return nil
    }

    return coordinator.managedObjectID(forURIRepresentation: persistentStoreURI)
}
