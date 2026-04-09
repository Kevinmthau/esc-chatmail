import Foundation

struct ComposeReplyModeContext {
    let initialRecipients: [Recipient]
    let outboundRequestContext: OutboundMessageRequest.ReplyContext
}

@MainActor
struct ComposeReplyModeContextBuilder {
    let outboundReplyContextBuilder: OutboundReplyContextBuilder

    struct Input {
        let initialRecipients: [Recipient]
        let conversation: ReplyConversationSnapshot
        let replyingTo: ReplyTargetSnapshot?
        let optimisticConversation: OutboundMessageRequest.OptimisticConversationContext?
    }

    func build(input: Input) -> ComposeReplyModeContext {
        return ComposeReplyModeContext(
            initialRecipients: input.initialRecipients,
            outboundRequestContext: outboundReplyContextBuilder.build(
                conversation: input.conversation,
                replyingTo: input.replyingTo,
                optimisticConversation: input.optimisticConversation
            )
        )
    }
}
