import Foundation
import CoreData

@MainActor
struct OutboundReplyContextBuilder {
    let viewContext: NSManagedObjectContext
    let replyMetadataBuilder: ReplyMetadataBuilder
    let replyHTMLContentLoader: HTMLContentLoader

    func build(
        conversationObjectID: NSManagedObjectID,
        replyingToMessageObjectID: NSManagedObjectID?,
        optimisticConversation: OptimisticConversationReference?
    ) -> OutboundMessageRequest.ReplyContext {
        return OutboundMessageRequest.ReplyContext(
            conversationObjectID: conversationObjectID,
            replyingToMessageObjectID: replyingToMessageObjectID,
            optimisticConversation: optimisticConversation
        )
    }

    func buildReplyMetadata(
        _ context: OutboundMessageRequest.ReplyContext
    ) throws -> OutboundMessageRequest.ReplyMetadata {
        guard let conversation = fetchConversation(objectID: context.conversationObjectID) else {
            throw GmailSendService.SendError.conversationNotFound
        }

        let replyingTo = context.replyingToMessageObjectID.flatMap(makeReplyTargetSnapshot)
        return replyMetadataBuilder.buildReplyMetadata(
            conversation: ReplyConversationSnapshot(conversation: conversation),
            replyingTo: replyingTo
        )
    }

    private func fetchConversation(objectID: NSManagedObjectID) -> Conversation? {
        do {
            return try viewContext.existingObject(with: objectID) as? Conversation
        } catch {
            Log.error(
                "Failed to fetch conversation for outbound reply metadata",
                category: .coreData,
                error: error
            )
            return nil
        }
    }

    private func makeReplyTargetSnapshot(objectID: NSManagedObjectID) -> ReplyTargetSnapshot? {
        let message: Message
        do {
            guard let fetchedMessage = try viewContext.existingObject(with: objectID) as? Message else {
                return nil
            }
            message = fetchedMessage
        } catch {
            Log.error(
                "Failed to fetch reply target for outbound reply metadata",
                category: .coreData,
                error: error
            )
            return nil
        }

        return ReplyTargetSnapshot(
            message: message,
            originalHTML: loadOriginalReplyHTML(for: message)
        )
    }

    private func loadOriginalReplyHTML(for message: Message) -> String? {
        replyHTMLContentLoader.loadReplyQuotedOriginalHTML(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyTextValue,
            senderEmail: message.senderEmailValue,
            subject: message.subject
        )
    }
}
