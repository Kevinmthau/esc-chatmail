import Foundation
import CoreData

@MainActor
struct OutboundReplyContextBuilder {
    let replyMetadataBuilder: ReplyMetadataBuilder

    func build(
        conversation: Conversation,
        replyingTo: Message?
    ) -> OutboundMessageRequest.ReplyContext {
        let conversationContext = makeConversationContext(conversation)
        let replyTarget = replyingTo.map(makeReplyTargetContext)
        let metadata = replyMetadataBuilder.buildReplyMetadata(
            conversation: conversationContext,
            replyingTo: replyTarget
        )

        return OutboundMessageRequest.ReplyContext(
            metadata: metadata,
            optimisticConversation: makeOptimisticConversationContext(conversation)
        )
    }

    private func makeConversationContext(
        _ conversation: Conversation
    ) -> ReplyMetadataBuilder.ConversationContext {
        ReplyMetadataBuilder.ConversationContext(
            participantEmails: Array(conversation.participants ?? [])
                .compactMap { $0.person?.email },
            latestThreadId: Array(conversation.messages ?? [])
                .sorted { $0.internalDate > $1.internalDate }
                .first?
                .gmThreadId
        )
    }

    private func makeOptimisticConversationContext(
        _ conversation: Conversation
    ) -> OutboundMessageRequest.OptimisticConversationContext {
        .init(
            existingConversationObjectURI: conversation.objectID.uriRepresentation().absoluteString
        )
    }

    private func makeReplyTargetContext(_ message: Message) -> ReplyMetadataBuilder.ReplyTargetContext {
        let references = message.referencesValue?
            .split(separator: " ")
            .map(String.init) ?? []

        return ReplyMetadataBuilder.ReplyTargetContext(
            subject: message.subject,
            threadId: message.gmThreadId,
            messageId: message.messageIdValue,
            references: references,
            originalMessage: QuotedMessage(
                senderName: message.senderNameValue,
                senderEmail: message.senderEmailValue ?? "",
                date: message.internalDate,
                body: message.bodyTextValue
            )
        )
    }
}
