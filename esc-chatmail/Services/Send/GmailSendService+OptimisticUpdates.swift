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
        optimisticConversation: OptimisticConversationReference? = nil
    ) async throws -> OptimisticSendHandle {
        // Pre-compute values that don't need Core Data
        let messageId = UUID().uuidString
        let snippet = String(body.prefix(120))
        let cleanedSnippet = EmailTextProcessor.createCleanSnippet(from: body, maxLength: Int.max, firstSentenceOnly: false)
        let gmThreadId = threadId ?? ""
        let hasAttachments = !attachments.isEmpty

        let conversation: Conversation
        if let existingConversationObjectID = optimisticConversation?.existingConversationReference?.resolveObjectID(in: viewContext) {
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
                participantHash: optimisticConversation?.participantHashValue
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

        return OptimisticSendHandle(
            optimisticMessageID: message.id,
            conversationReference: ConversationReference(objectID: conversation.objectID)
        )
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
        let conversationCleanup = OptimisticFailureConversationCleanup(message: message)
        viewContext.delete(message)
        finalizeOptimisticFailureCleanup(conversationCleanup)

        saveOptimisticFailureCleanup()
    }

    @MainActor
    private func saveOptimisticFailureCleanup() {
        do {
            if viewContext.hasChanges {
                try viewContext.save()
            }
        } catch {
            Log.error("Failed to save optimistic failure cleanup", category: .message, error: error)
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

        let conversationCleanup = OptimisticFailureConversationCleanup(message: message)
        for attachment in localAttachments {
            attachment.state = .failed
        }
        finalizeOptimisticFailureCleanup(conversationCleanup)
        saveOptimisticFailureCleanup()
    }

    @MainActor
    func handleFailedOptimisticMessage(
        byID messageID: String,
        fallbackAttachmentReferences: [LocalAttachmentReference]
    ) {
        if let message = fetchMessageSync(byID: messageID) {
            handleFailedOptimisticMessage(message)
            return
        }

        let fallbackAttachments = resolveAttachments(from: fallbackAttachmentReferences)
        guard !fallbackAttachments.isEmpty else { return }
        markAttachmentsAsFailed(fallbackAttachments)
    }

    @MainActor
    private func finalizeOptimisticFailureCleanup(_ cleanup: OptimisticFailureConversationCleanup?) {
        guard let cleanup,
              let conversation = cleanup.conversation,
              conversation.managedObjectContext != nil else {
            return
        }

        viewContext.processPendingChanges()

        guard !conversation.isDeleted else { return }

        let remainingMessages = conversation.messages?.filter { !$0.isDeleted } ?? []
        if cleanup.wasInserted && remainingMessages.isEmpty {
            viewContext.delete(conversation)
            return
        }

        ConversationRollupUpdater().updateRollups(
            for: conversation,
            myEmail: authSession.userEmail ?? ""
        )

        cleanup.restorePreOptimisticConversationStateIfNeeded()
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
            from: contexts.map(\.localAttachmentReference)
        )
    }

    @MainActor
    private func resolveAttachments(from references: [LocalAttachmentReference]) -> [Attachment] {
        references.compactMap { reference in
            guard let objectID = reference.resolveObjectID(in: viewContext) else { return nil }
            return try? viewContext.existingObject(with: objectID) as? Attachment
        }
    }
}

private struct OptimisticFailureConversationCleanup {
    let conversation: Conversation?
    let wasInserted: Bool
    private let archivedAtBeforeOptimisticChanges: Date?
    private let hiddenBeforeOptimisticChanges: Bool
    private let displayNameBeforeOptimisticChanges: String?

    @MainActor
    init(message: Message) {
        guard let conversation = message.conversation else {
            self.conversation = nil
            self.wasInserted = false
            self.archivedAtBeforeOptimisticChanges = nil
            self.hiddenBeforeOptimisticChanges = false
            self.displayNameBeforeOptimisticChanges = nil
            return
        }

        let committedValues = conversation.committedValues(
            forKeys: ["archivedAt", "hidden", "displayName"]
        )

        self.conversation = conversation
        self.wasInserted = conversation.isInserted
        self.archivedAtBeforeOptimisticChanges = committedValues["archivedAt"] as? Date
        self.hiddenBeforeOptimisticChanges = Self.boolValue(
            from: committedValues["hidden"],
            defaultValue: conversation.hidden
        )
        self.displayNameBeforeOptimisticChanges = committedValues["displayName"] as? String
    }

    @MainActor
    func restorePreOptimisticConversationStateIfNeeded() {
        guard let conversation else { return }

        if !wasInserted {
            conversation.displayName = displayNameBeforeOptimisticChanges
        }

        guard let archivedAtBeforeOptimisticChanges,
              !conversation.hasInbox else {
            return
        }

        conversation.archivedAt = archivedAtBeforeOptimisticChanges
        conversation.hidden = hiddenBeforeOptimisticChanges
    }

    private static func boolValue(from value: Any?, defaultValue: Bool) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return defaultValue
    }
}
