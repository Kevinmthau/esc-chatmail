import Foundation

@MainActor
struct OutboundReplyContextBuilder {
    let replyMetadataBuilder: ReplyMetadataBuilder

    func build(
        conversation: ReplyConversationSnapshot,
        replyingTo: ReplyTargetSnapshot?,
        optimisticConversation: OptimisticConversationReference?
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
