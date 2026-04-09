import Foundation
import CoreData

// MARK: - Optimistic Message Updates

extension GmailSendService {

    /// Creates an optimistic local message before the actual send completes.
    /// This provides immediate feedback to the user.
    @MainActor
    func createOptimisticMessage(
        to recipients: [String],
        body: String,
        subject: String? = nil,
        threadId: String? = nil,
        attachments: [OutboundMessageRequest.AttachmentContext] = [],
        optimisticConversation: OutboundMessageRequest.OptimisticConversationContext? = nil
    ) async throws -> Message {
        // Pre-compute values that don't need Core Data
        let messageId = UUID().uuidString
        let snippet = String(body.prefix(120))
        let cleanedSnippet = EmailTextProcessor.createCleanSnippet(from: body, maxLength: Int.max, firstSentenceOnly: false)
        let gmThreadId = threadId ?? ""
        let hasAttachments = !attachments.isEmpty

        let conversation: Conversation
        if let existingConversationObjectID = resolveObjectID(
            from: optimisticConversation?.existingConversationObjectURI
        ) {
            // Replies from an open chat should always attach to the currently visible
            // conversation so the optimistic bubble appears immediately in-thread.
            if let registered = viewContext.registeredObject(for: existingConversationObjectID) as? Conversation {
                conversation = registered
            } else if let fetched = try? viewContext.existingObject(with: existingConversationObjectID) as? Conversation {
                conversation = fetched
            } else {
                Log.error("Failed to resolve existing conversation for optimistic message", category: .message)
                throw SendError.conversationNotFound
            }
        } else {
            conversation = try findOrCreateOptimisticConversation(
                participantHash: optimisticConversation?.participantHash
                    ?? makeOptimisticParticipantHash(from: recipients),
                recipients: recipients,
                in: viewContext
            )
        }

        let message = Message(context: viewContext)
        message.id = messageId
        message.isFromMe = true
        message.internalDate = Date()
        message.snippet = snippet
        message.cleanedSnippet = cleanedSnippet
        message.bodyText = body
        message.gmThreadId = gmThreadId
        message.subject = subject
        message.hasAttachments = hasAttachments

        let attachmentObjects = resolveAttachments(from: attachments)

        // Add attachments to message
        for attachment in attachmentObjects {
            attachment.setValue(message, forKey: "message")
            attachment.state = .queued
        }

        message.conversation = conversation

        // Update conversation to bump it to the top
        conversation.lastMessageDate = Date()
        conversation.snippet = message.conversationPreviewText
        // IMPORTANT: do NOT set conversation.hasInbox = true here for outgoing messages

        // Keep the optimistic graph unsaved so chat navigation is not blocked by a
        // main-thread Core Data save, especially for image attachments. Stabilize the
        // objectIDs up front so SwiftUI navigation can still target the new thread.
        assignPermanentObjectIDsIfNeeded(
            for: optimisticGraphObjects(
                conversation: conversation,
                message: message,
                attachments: attachmentObjects
            ),
            in: viewContext
        )
        viewContext.processPendingChanges()

        return message
    }

    /// Fetches a message by its ID (async to avoid blocking main thread).
    func fetchMessage(byID messageID: String) async -> Message? {
        await viewContext.perform { [viewContext] in
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id(messageID)
            request.fetchLimit = 1
            request.fetchBatchSize = 1

            do {
                return try viewContext.fetch(request).first
            } catch {
                Log.error("Failed to fetch message", category: .message, error: error)
                return nil
            }
        }
    }

    /// Fetches a message by its ID synchronously (for use on MainActor where viewContext is safe).
    @MainActor
    func fetchMessageSync(byID messageID: String) -> Message? {
        let request = Message.fetchRequest()
        request.predicate = MessagePredicates.id(messageID)
        request.fetchLimit = 1
        request.fetchBatchSize = 1

        do {
            return try viewContext.fetch(request).first
        } catch {
            Log.error("Failed to fetch message", category: .message, error: error)
            return nil
        }
    }

    /// Updates an optimistic message with the actual Gmail IDs after successful send.
    @MainActor
    func updateOptimisticMessage(_ message: Message, with result: SendResult) {
        message.id = result.messageId
        message.gmThreadId = result.threadId

        do {
            if viewContext.hasChanges {
                try viewContext.save()
            }
        } catch {
            Log.error("Failed to update message with Gmail ID", category: .message, error: error)
        }
    }

    /// Deletes an optimistic message (used when send fails).
    @MainActor
    func deleteOptimisticMessage(_ message: Message) {
        viewContext.delete(message)

        do {
            if viewContext.hasChanges {
                try viewContext.save()
            }
        } catch {
            Log.error("Failed to delete optimistic message", category: .message, error: error)
        }
    }

    /// Handles optimistic message cleanup after a send failure.
    ///
    /// Messages with local attachments are retained and marked failed so the bubble
    /// can show an inline "Send failed" indicator. Messages without local attachments
    /// are removed to avoid leaving an unsent bubble that appears delivered.
    @MainActor
    func handleFailedOptimisticMessage(_ message: Message) {
        let localAttachments = message.attachmentsArray.filter(\.isLocalAttachment)
        guard !localAttachments.isEmpty else {
            deleteOptimisticMessage(message)
            return
        }
        markAttachmentsAsFailed(localAttachments)
    }

    @MainActor
    func handleFailedOptimisticMessage(
        byID messageID: String,
        fallbackAttachmentObjectURIs: [String]
    ) {
        if let message = fetchMessageSync(byID: messageID) {
            handleFailedOptimisticMessage(message)
            return
        }

        let fallbackAttachments = resolveAttachments(from: fallbackAttachmentObjectURIs)
        guard !fallbackAttachments.isEmpty else { return }
        markAttachmentsAsFailed(fallbackAttachments)
    }

    /// Finds or creates a conversation for the optimistic send path without forcing
    /// an immediate save on the main context.
    @MainActor
    func findOrCreateOptimisticConversation(
        participantHash: String,
        recipients: [String],
        in context: NSManagedObjectContext
    ) throws -> Conversation {
        let request = Conversation.fetchRequest()
        request.predicate = NSPredicate(format: "participantHash == %@", participantHash)
        request.fetchBatchSize = 10
        request.includesPendingChanges = true

        let matchingConversations: [Conversation]
        do {
            matchingConversations = try context.fetch(request)
        } catch {
            Log.error("Failed to fetch optimistic conversation for participantHash", category: .coreData, error: error)
            throw SendError.conversationNotFound
        }

        if let activeConversation = matchingConversations.first(where: { $0.archivedAt == nil }) {
            activeConversation.displayName = DisplayNameFormatter.formatGroupNames(recipients)
            return activeConversation
        }

        if let archivedConversation = matchingConversations.first {
            archivedConversation.archivedAt = nil
            archivedConversation.hidden = false
            archivedConversation.displayName = DisplayNameFormatter.formatGroupNames(recipients)
            Log.debug("Un-archived conversation \(archivedConversation.id) due to optimistic new message", category: .conversation)
            return archivedConversation
        }

        let identityHeaders = recipients.map { MessageHeader(name: "To", value: $0) }
        let identity = makeConversationIdentity(from: identityHeaders, myAliases: [])
        let conversation = try ConversationFactory.create(
            for: identity,
            initialLastMessageDate: Date(),
            in: context
        )

        // Update display name for sent messages
        conversation.displayName = DisplayNameFormatter.formatGroupNames(recipients)

        return conversation
    }

    @MainActor
    private func optimisticGraphObjects(
        conversation: Conversation,
        message: Message,
        attachments: [Attachment]
    ) -> [NSManagedObject] {
        var objects: [NSManagedObject] = [conversation, message]
        objects.append(contentsOf: attachments)

        if let participants = conversation.participants {
            objects.append(contentsOf: participants)
            objects.append(contentsOf: participants.compactMap(\.person))
        }

        return objects.filter { $0.managedObjectContext === viewContext }
    }

    @MainActor
    private func assignPermanentObjectIDsIfNeeded(
        for objects: [NSManagedObject],
        in context: NSManagedObjectContext
    ) {
        let temporaryObjects = objects.filter { $0.objectID.isTemporaryID }
        guard !temporaryObjects.isEmpty else { return }

        do {
            try context.obtainPermanentIDs(for: temporaryObjects)
        } catch {
            Log.error("Failed to obtain permanent IDs for optimistic send", category: .message, error: error)
        }
    }

    private func makeOptimisticParticipantHash(from recipients: [String]) -> String {
        let normalizedParticipants = Array(
            Set(recipients.map(normalizedEmail).filter { !$0.isEmpty })
        )
        return calculateParticipantHash(from: normalizedParticipants)
    }

    @MainActor
    private func resolveAttachments(
        from contexts: [OutboundMessageRequest.AttachmentContext]
    ) -> [Attachment] {
        resolveAttachments(
            from: contexts.map(\.localStateAttachmentURI)
        )
    }

    @MainActor
    private func resolveAttachments(from uris: [String]) -> [Attachment] {
        uris.compactMap { uri in
            guard let objectID = resolveObjectID(from: uri) else { return nil }
            return try? viewContext.existingObject(with: objectID) as? Attachment
        }
    }

    @MainActor
    private func resolveObjectID(from uri: String?) -> NSManagedObjectID? {
        guard let uri,
              let url = URL(string: uri),
              let coordinator = viewContext.persistentStoreCoordinator else {
            return nil
        }

        return coordinator.managedObjectID(forURIRepresentation: url)
    }
}
