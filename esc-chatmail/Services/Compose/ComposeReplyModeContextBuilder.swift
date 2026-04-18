import Foundation
import CoreData

struct ComposeReplyModeContext {
    let initialRecipients: [Recipient]
    let outboundRequestContext: OutboundMessageRequest.ReplyContext
}

@MainActor
struct ComposeReplyModeContextBuilder {
    let outboundReplyContextBuilder: OutboundReplyContextBuilder

    struct Input {
        let initialRecipients: [Recipient]
        let conversationObjectID: NSManagedObjectID
        let replyingToMessageObjectID: NSManagedObjectID?
        let optimisticConversation: OptimisticConversationReference?
    }

    func build(input: Input) -> ComposeReplyModeContext {
        return ComposeReplyModeContext(
            initialRecipients: input.initialRecipients,
            outboundRequestContext: outboundReplyContextBuilder.build(
                conversationObjectID: input.conversationObjectID,
                replyingToMessageObjectID: input.replyingToMessageObjectID,
                optimisticConversation: input.optimisticConversation
            )
        )
    }
}
