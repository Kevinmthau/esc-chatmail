import Foundation
import CoreData

@MainActor
struct OutboundReplyContextBuilder {
    let viewContext: NSManagedObjectContext
    let replyMetadataBuilder: ReplyMetadataBuilder
    let replyQuotedHTMLResolver: ReplyQuotedHTMLResolver
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
        optimisticConversation: OptimisticConversationReference?,
        includesQuotedMessage: Bool = true
    ) -> OutboundMessageRequest.ReplyContext {
        return OutboundMessageRequest.ReplyContext(
            conversationObjectID: conversationObjectID,
            replyingToMessageObjectID: replyingToMessageObjectID,
            optimisticConversation: optimisticConversation,
            includesQuotedMessage: includesQuotedMessage
        )
    }

    func buildReplyMetadata(
        _ context: OutboundMessageRequest.ReplyContext
    ) async throws -> OutboundMessageRequest.ReplyMetadata {
        let reply = try await resolveReply(context, resolvesReplyAddressHint: true)
        return try replyMetadataBuilder.buildReplyMetadata(
            conversation: reply.conversation,
            replyingTo: reply.replyingTo,
            sendAsAliases: reply.sendAsAliases,
            userAliases: reply.userAliases,
            includesQuotedMessage: context.includesQuotedMessage
        )
    }

    /// Who the reply `context` describes would go to if it were sent now: the
    /// send's own decision (`ReplyMetadataBuilder.replyAddressing`), read from
    /// the same stored conversation and message the send reads.
    ///
    /// For the composer, which names the recipients above its field when they
    /// are not the chat's own people. Nil where the send would refuse the
    /// reply (a conversation or a target that is gone): there is then nothing
    /// to announce, and the send says why.
    ///
    /// It leaves out the one thing of the send's reading that addressing does
    /// not use, the search for an address to reply from: that can page through
    /// the whole conversation, and this runs as a chat opens and after every
    /// sync.
    func replyAddressing(
        _ context: OutboundMessageRequest.ReplyContext
    ) async -> ReplyAddressing? {
        guard let reply = try? await resolveReply(context, resolvesReplyAddressHint: false) else {
            return nil
        }
        return replyMetadataBuilder.replyAddressing(
            conversation: reply.conversation,
            replyingTo: reply.replyingTo,
            sendAsAliases: reply.sendAsAliases,
            userAliases: reply.userAliases
        )
    }

    /// Whether a reply in `conversation` to `message` (nil: to its newest
    /// message) may go to other people than the conversation's own, told in
    /// this turn and without loading aliases
    /// (`ReplyMetadataBuilder.rowsCertainlyAnswer`). False is certain: the
    /// reply goes to the rows' people, or the conversation or the message is
    /// gone and the send would refuse the reply. True means only that
    /// `replyAddressing` has to be asked. Despite its name it covers every
    /// rule that addresses a reply away from the rows' people, a Reply-To
    /// header's as well as the overruling one.
    ///
    /// It takes the objects the chat already holds and reads the
    /// conversation's rows and the one message, not the whole
    /// `ReplyConversationSnapshot`, which looks through the conversation for
    /// a reply-address hint: this runs whenever a chat's reply target changes,
    /// the first time as the chat opens.
    func replyMayOverruleConversationRows(
        in conversation: Conversation,
        replyingTo message: Message?
    ) -> Bool {
        guard conversation.managedObjectContext != nil,
              !conversation.isDeleted,
              !conversation.isRetainedDrainedShell,
              conversation.conversationType != .list else {
            return false
        }

        let target: ReplyTargetSnapshot?
        if let message {
            guard message.managedObjectContext != nil, !message.isDeleted else { return false }
            target = ReplyTargetSnapshot(message: message)
        } else {
            target = ReplyConversationSnapshot.latestNonListReplyTarget(in: conversation)
        }
        return !replyMetadataBuilder.rowsCertainlyAnswer(
            conversationRowEmails: ReplyConversationSnapshot.participantRowEmails(of: conversation),
            isListConversation: false,
            target: target,
            // The stored send-as addresses, which the send counts among the
            // user's own too. One fetch of the account row, made only for a
            // Reply-To target: mail delivered to one of them would otherwise
            // never be settled in this turn.
            knownUserAddresses: { loadSendAsAliases().map(\.emailAddress) }
        )
    }

    /// The stored state a reply is built from, read once for
    /// `buildReplyMetadata` and `replyAddressing` alike so the two cannot
    /// read a conversation differently.
    private struct ResolvedReply {
        let conversation: ReplyConversationSnapshot
        let replyingTo: ReplyTargetSnapshot?
        let sendAsAliases: [SendAsAlias]
        let userAliases: Set<String>
    }

    /// - Parameter resolvesReplyAddressHint: Whether to look through the
    ///   conversation for an address to reply from where the target names
    ///   none. A send needs it; who the reply goes to does not depend on it.
    private func resolveReply(
        _ context: OutboundMessageRequest.ReplyContext,
        resolvesReplyAddressHint: Bool
    ) async throws -> ResolvedReply {
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
            throw GmailSendService.SendError.replyConversationUnavailable
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
        return ResolvedReply(
            conversation: ReplyConversationSnapshot(
                conversation: conversation,
                replyingTo: replyingTo,
                sendAsAliases: sendAsAliases,
                resolvesReplyAddressHint: resolvesReplyAddressHint
            ),
            replyingTo: replyingTo,
            sendAsAliases: sendAsAliases,
            userAliases: userAliases
        )
    }

    func validateRecoveredReply(_ metadata: OutboundMessageRequest.ReplyMetadata,
                                context: OutboundMessageRequest.ReplyContext) throws {
        guard let conversation = fetchConversation(objectID: context.conversationObjectID),
              !conversation.isDeleted, !conversation.isRetainedDrainedShell else {
            throw GmailSendService.SendError.replyConversationUnavailable
        }
        let auth = replyMetadataBuilder.authSession
        let selected = try ReplyFromAddressSelector(
            sendAsAliases: loadSendAsAliases(), fallbackEmail: auth.userEmail, fallbackDisplayName: auth.userName
        ).select(replyFromAddress: metadata.fromEmail, deliveredToAddress: nil)
        guard EmailNormalizer.normalize(selected.emailAddress) == EmailNormalizer.normalize(metadata.fromEmail) else {
            throw GmailSendService.SendError.sendAsAliasUnavailable(metadata.fromEmail)
        }
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
