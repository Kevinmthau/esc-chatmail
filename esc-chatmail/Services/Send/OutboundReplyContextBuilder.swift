import Foundation
import CoreData

@MainActor
struct OutboundReplyContextBuilder {
    let viewContext: NSManagedObjectContext
    let replyMetadataBuilder: ReplyMetadataBuilder
    private let replyQuotedHTMLResolver: ReplyQuotedHTMLResolver
    private let loadUserAliases: @MainActor () async -> Set<String>

    init(
        viewContext: NSManagedObjectContext,
        replyMetadataBuilder: ReplyMetadataBuilder,
        replyHTMLContentLoader: HTMLContentLoader,
        replyQuotedHTMLResolver: ReplyQuotedHTMLResolver? = nil,
        loadUserAliases: (@MainActor () async -> Set<String>)? = nil
    ) {
        self.viewContext = viewContext
        self.replyMetadataBuilder = replyMetadataBuilder
        self.replyQuotedHTMLResolver = replyQuotedHTMLResolver ?? ReplyQuotedHTMLResolver(
            contentLoader: replyHTMLContentLoader
        )
        self.loadUserAliases = loadUserAliases ?? {
            await AliasManager.shared.getAliases(from: viewContext)
        }
    }

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
    ) async throws -> OutboundMessageRequest.ReplyMetadata {
        guard fetchConversation(objectID: context.conversationObjectID) != nil else {
            throw GmailSendService.SendError.conversationNotFound
        }

        let sendAsAliases = loadSendAsAliases()
        let userAliases = await loadUserAliases()
        // Alias loading yields the MainActor. Re-resolve the anchor afterward
        // so a conversation drained by sync during that suspension cannot
        // supply stale recipients to the outbound request.
        guard let conversation = fetchConversation(objectID: context.conversationObjectID),
              conversation.managedObjectContext != nil,
              !conversation.isDeleted,
              !conversation.isRetainedDrainedShell else {
            throw GmailSendService.SendError.replyTargetUnavailable
        }
        let replyingTo: ReplyTargetSnapshot?
        if let replyingToMessageObjectID = context.replyingToMessageObjectID {
            guard let snapshot = makeReplyTargetSnapshot(
                objectID: replyingToMessageObjectID,
                anchoredTo: conversation,
                sendAsAliases: sendAsAliases
            ) else {
                throw GmailSendService.SendError.replyTargetUnavailable
            }
            replyingTo = snapshot
        } else {
            replyingTo = nil
        }
        return try replyMetadataBuilder.buildReplyMetadata(
            conversation: ReplyConversationSnapshot(
                conversation: conversation,
                replyingTo: replyingTo,
                sendAsAliases: sendAsAliases
            ),
            replyingTo: replyingTo,
            sendAsAliases: sendAsAliases,
            userAliases: userAliases
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
        anchoredTo conversation: Conversation,
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

        guard message.conversation?.objectID == conversation.objectID else {
            Log.warning(
                "Reply target no longer belongs to the anchored conversation",
                category: .message
            )
            return nil
        }

        guard OutboundSendDeliveryState.resolve(for: message) == .none else {
            Log.warning(
                "Rejecting local outbound delivery state as a reply target",
                category: .message
            )
            return nil
        }

        if conversation.conversationType == .list {
            guard let conversationListId = conversation.listId,
                  !conversationListId.isEmpty,
                  message.listId == conversationListId else {
                Log.warning(
                    "Reply target List-Id no longer matches the anchored conversation",
                    category: .message
                )
                return nil
            }
        }

        let deferredOriginalHTML = DeferredReplyQuotedHTML(
            source: ReplyQuotedHTMLSource(
                messageId: message.id,
                bodyStorageURI: message.bodyStorageURI,
                bodyText: message.bodyTextValue,
                senderEmail: message.senderEmailValue,
                subject: message.subject
            ),
            resolver: replyQuotedHTMLResolver
        )

        return ReplyTargetSnapshot(
            message: message,
            sendAsAliases: sendAsAliases,
            deferredOriginalHTML: deferredOriginalHTML
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
