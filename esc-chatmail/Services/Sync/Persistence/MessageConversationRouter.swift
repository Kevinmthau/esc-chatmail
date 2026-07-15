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
        in context: NSManagedObjectContext
    ) async throws -> NSManagedObjectID {
        let shouldReactivateConversation = routingPolicy.shouldReactivateArchivedConversation(
            labelIDs: processedMessage.labelIds,
            isFromMe: processedMessage.headers.isFromMe
        )

        let identity = conversationManager.createConversationIdentity(
            from: processedMessage.headers,
            gmThreadId: processedMessage.gmThreadId,
            myAliases: myAliases
        )

        return try await conversationManager.findOrCreateConversationObjectID(
            for: identity,
            initialLastMessageDate: processedMessage.internalDate,
            initialSnippet: processedMessage.conversationPreviewText,
            initialInboxSeed: ConversationInboxSeed(
                isInboxArrival: processedMessage.labelIds.contains("INBOX"),
                isUnread: processedMessage.isUnread,
                messageDate: processedMessage.internalDate
            ),
            reactivateArchivedIfNeeded: shouldReactivateConversation,
            in: context
        )
    }
}
