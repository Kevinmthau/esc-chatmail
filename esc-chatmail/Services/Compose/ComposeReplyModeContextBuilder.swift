import Foundation
import CoreData

struct ComposeReplyModeContext {
    let initialRecipients: [Recipient]
    let outboundRequestContext: OutboundMessageRequest.ReplyContext
}

@MainActor
struct ComposeReplyModeContextBuilder {
    let authSession: AuthSession
    let outboundReplyContextBuilder: OutboundReplyContextBuilder

    func build(
        conversation: Conversation,
        replyingTo: Message?
    ) -> ComposeReplyModeContext {
        let currentUserEmail = authSession.userEmail ?? ""
        let initialRecipients = Array(conversation.participants ?? [])
            .compactMap { participant -> Recipient? in
                guard let person = participant.person else { return nil }
                guard EmailNormalizer.normalize(person.email) != EmailNormalizer.normalize(currentUserEmail) else {
                    return nil
                }

                return Recipient(from: person)
            }

        return ComposeReplyModeContext(
            initialRecipients: initialRecipients,
            outboundRequestContext: outboundReplyContextBuilder.build(
                conversation: conversation,
                replyingTo: replyingTo
            )
        )
    }
}
