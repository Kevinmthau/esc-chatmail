import Foundation
import CoreData

/// Resolves which conversation a newly persisted message should belong to.
///
/// Routing is strictly participant-based: every message is keyed by the set of
/// people on it (From+To+Cc minus the user's aliases), independent of Gmail's
/// thread grouping. The routing rules combine:
/// - participant-set identity (`participantHash`)
/// - archived conversation reactivation (epoch policy)
final class MessageConversationRouter {
    private let conversationManager: ConversationManager
    private let routingPolicy: ConversationRoutingPolicy

    init(
        conversationManager: ConversationManager = ConversationManager(),
        routingPolicy: ConversationRoutingPolicy = ConversationRoutingPolicy()
    ) {
        self.conversationManager = conversationManager
        self.routingPolicy = routingPolicy
    }

    func resolveConversationObjectID(
        for processedMessage: ProcessedMessage,
        myAliases: Set<String>,
        reuseArchivedWithoutReactivation: Bool = false,
        in context: NSManagedObjectContext
    ) async throws -> NSManagedObjectID {
        let shouldReactivateConversation = routingPolicy.shouldReactivateArchivedConversation(
            labelIDs: processedMessage.labelIds,
            isFromMe: processedMessage.headers.isFromMe
        )

        let identity = conversationManager.createConversationIdentity(
            from: processedMessage.headers,
            myAliases: myAliases
        )

        if reuseArchivedWithoutReactivation,
           let existingObjectID = try await existingConversationObjectID(
               for: identity,
               in: context
           ) {
            return existingObjectID
        }

        return try await conversationManager.findOrCreateConversationObjectID(
            for: identity,
            initialLastMessageDate: processedMessage.internalDate,
            initialSnippet: processedMessage.conversationPreviewText,
            initialInboxSeed: ConversationInboxSeed(
                isInboxArrival: processedMessage.labelIds.contains("INBOX"),
                isUnread: processedMessage.isUnread,
                messageDate: processedMessage.internalDate
            ),
            reactivateArchivedIfNeeded: reuseArchivedWithoutReactivation
                ? false
                : shouldReactivateConversation,
            in: context
        )
    }

    /// Existing-message repair must not apply new-arrival epoch semantics. If a
    /// durable List-Id conversation already exists, reuse it whether active or
    /// archived and leave its archive state untouched.
    private func existingConversationObjectID(
        for identity: ConversationIdentity,
        in context: NSManagedObjectContext
    ) async throws -> NSManagedObjectID? {
        let routingPolicy = self.routingPolicy
        return try await context.perform { () throws -> NSManagedObjectID? in
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(
                format: "participantHash == %@ AND listId == %@",
                identity.participantHash,
                identity.listId ?? ""
            )
            request.fetchBatchSize = 10
            request.includesPendingChanges = false

            let conversations = try context.fetch(request)
            return routingPolicy.selectParticipantHashConversation(
                from: conversations,
                reactivateArchivedIfNeeded: true
            )?.objectID
        }
    }
}
