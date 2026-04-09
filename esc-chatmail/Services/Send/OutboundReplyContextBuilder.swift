import Foundation

@MainActor
struct OutboundReplyContextBuilder {
    let replyMetadataBuilder: ReplyMetadataBuilder

    func build(
        conversation: ReplyMetadataBuilder.ConversationContext,
        replyingTo: ReplyMetadataBuilder.ReplyTargetContext?,
        optimisticConversation: OutboundMessageRequest.OptimisticConversationContext?
    ) -> OutboundMessageRequest.ReplyContext {
        let metadata = replyMetadataBuilder.buildReplyMetadata(
            conversation: conversation,
            replyingTo: replyingTo
        )

        return OutboundMessageRequest.ReplyContext(
            metadata: metadata,
            optimisticConversation: optimisticConversation
        )
    }
}
