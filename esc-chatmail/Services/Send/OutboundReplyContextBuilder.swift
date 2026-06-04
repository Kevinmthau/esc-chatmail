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

        let sendAsAliases = loadSendAsAliases()
        let replyingTo = context.replyingToMessageObjectID.flatMap {
            makeReplyTargetSnapshot(objectID: $0, sendAsAliases: sendAsAliases)
        }
        return try replyMetadataBuilder.buildReplyMetadata(
            conversation: ReplyConversationSnapshot(
                conversation: conversation,
                sendAsAliases: sendAsAliases
            ),
            replyingTo: replyingTo,
            sendAsAliases: sendAsAliases
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

    private func makeReplyTargetSnapshot(
        objectID: NSManagedObjectID,
        sendAsAliases: [SendAsAlias]
    ) -> ReplyTargetSnapshot? {
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
            sendAsAliases: sendAsAliases,
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

    private func loadSendAsAliases() -> [SendAsAlias] {
        let request = Account.fetchRequest()
        request.fetchLimit = 1

        do {
            guard let account = try viewContext.fetch(request).first else {
                return []
            }

            let aliases = account.sendAsAliasesArray
            guard !aliases.isEmpty else {
                return SendAsAlias.deduplicated(
                    ([account.email] + account.aliasesArray).map {
                        SendAsAlias(
                            emailAddress: $0,
                            isDefault: $0.caseInsensitiveCompare(account.email) == .orderedSame,
                            isPrimary: $0.caseInsensitiveCompare(account.email) == .orderedSame,
                            verificationStatus: "accepted"
                        )
                    }
                )
            }

            return aliases
        } catch {
            Log.error("Failed to fetch send-as aliases for reply metadata", category: .coreData, error: error)
            return []
        }
    }
}
