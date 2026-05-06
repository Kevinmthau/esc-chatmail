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
        let rollbackSnapshot = OptimisticSendMutationSnapshot(
            optimisticMessageID: messageId,
            conversation: conversation
        )
        do {
            try persistOptimisticSendMutationRecord(rollbackSnapshot)
        } catch {
            Log.error("Failed to persist optimistic send mutation record", category: .message, error: error)
            rollbackOptimisticCreation(message, snapshot: rollbackSnapshot)
            throw SendError.optimisticCreationFailed
        }
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
        let optimisticMessageID = message.id
        deleteOptimisticSendMutationRecord(messageID: optimisticMessageID)
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
        let optimisticMessageID = message.id
        let conversationCleanup = OptimisticFailureConversationCleanup(
            message: message,
            persistedSnapshot: fetchOptimisticSendMutationSnapshot(messageID: optimisticMessageID)
        )
        viewContext.delete(message)
        finalizeOptimisticFailureCleanup(conversationCleanup, restoreRollupFields: true)
        deleteOptimisticSendMutationRecord(messageID: optimisticMessageID)

        saveOptimisticFailureCleanup()
    }

    @MainActor
    private func rollbackOptimisticCreation(
        _ message: Message,
        snapshot: OptimisticSendMutationSnapshot
    ) {
        let conversationCleanup = OptimisticFailureConversationCleanup(
            message: message,
            persistedSnapshot: snapshot
        )
        viewContext.delete(message)
        finalizeOptimisticFailureCleanup(conversationCleanup, restoreRollupFields: true)
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
        let optimisticMessageID = message.id
        let persistedSnapshot = fetchOptimisticSendMutationSnapshot(messageID: optimisticMessageID)
        let localAttachments = message.attachmentsArray.filter(\.isLocalAttachment)
        guard !localAttachments.isEmpty else {
            deleteOptimisticMessage(message)
            return
        }

        let conversationCleanup = OptimisticFailureConversationCleanup(
            message: message,
            persistedSnapshot: persistedSnapshot
        )
        for attachment in localAttachments {
            attachment.state = .failed
        }
        finalizeOptimisticFailureCleanup(conversationCleanup, restoreRollupFields: false)
        deleteOptimisticSendMutationRecord(messageID: optimisticMessageID)
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

        restoreConversationStateForMissingOptimisticMessage(messageID: messageID)

        let fallbackAttachments = resolveAttachments(from: fallbackAttachmentReferences)
        guard !fallbackAttachments.isEmpty else { return }
        markAttachmentsAsFailed(fallbackAttachments)
    }

    @MainActor
    private func finalizeOptimisticFailureCleanup(
        _ cleanup: OptimisticFailureConversationCleanup?,
        restoreRollupFields: Bool
    ) {
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

        let hasSupersedingMessage = cleanup.hasRemainingMessageSupersedingOptimisticMessage(remainingMessages)
        cleanup.restorePreOptimisticConversationStateIfNeeded(
            restoreRollupFields: restoreRollupFields && !hasSupersedingMessage,
            restoreArchiveState: !hasSupersedingMessage
        )
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

        let routingPolicy = ConversationRoutingPolicy()
        if let existingConversation = routingPolicy.selectParticipantHashConversation(
            from: matchingConversations,
            reactivateArchivedIfNeeded: true
        ) {
            routingPolicy.reactivateArchivedConversationIfNeeded(
                existingConversation,
                shouldReactivate: true
            )
            existingConversation.displayName = DisplayNameFormatter.formatGroupNames(recipients)
            return existingConversation
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

    @MainActor
    @discardableResult
    func reconcileAbandonedOptimisticSendMutations() -> Bool {
        let messageIDs = fetchAllOptimisticSendMutationRecords().map(\.id)
        guard !messageIDs.isEmpty else { return false }

        Log.info("Reconciling \(messageIDs.count) abandoned optimistic send mutation(s)", category: .message)
        for messageID in messageIDs {
            handleFailedOptimisticMessage(
                byID: messageID,
                fallbackAttachmentReferences: []
            )
        }
        return true
    }

    @MainActor
    private func persistOptimisticSendMutationRecord(_ snapshot: OptimisticSendMutationSnapshot) throws {
        guard let coordinator = viewContext.persistentStoreCoordinator else {
            throw SendError.optimisticCreationFailed
        }

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        try context.performAndWait {
            let record = fetchOptimisticSendMutationRecords(
                messageID: snapshot.optimisticMessageID,
                in: context
            ).first
                ?? OutboundSendMutationRecord(context: context)
            snapshot.apply(to: record)

            if context.hasChanges {
                try context.save()
            }
        }
    }

    @MainActor
    private func fetchOptimisticSendMutationSnapshot(messageID: String) -> OptimisticSendMutationSnapshot? {
        fetchOptimisticSendMutationRecords(messageID: messageID).first.map(OptimisticSendMutationSnapshot.init(record:))
    }

    @MainActor
    private func fetchOptimisticSendMutationRecords(messageID: String) -> [OutboundSendMutationRecord] {
        fetchOptimisticSendMutationRecords(messageID: messageID, in: viewContext)
    }

    private func fetchOptimisticSendMutationRecords(
        messageID: String,
        in context: NSManagedObjectContext
    ) -> [OutboundSendMutationRecord] {
        let request = OutboundSendMutationRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", messageID)
        request.includesPendingChanges = true

        do {
            return try context.fetch(request)
        } catch {
            Log.error("Failed to fetch optimistic send mutation record", category: .message, error: error)
            return []
        }
    }

    @MainActor
    private func fetchAllOptimisticSendMutationRecords() -> [OutboundSendMutationRecord] {
        let request = OutboundSendMutationRecord.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        request.includesPendingChanges = true

        do {
            return try viewContext.fetch(request)
        } catch {
            Log.error("Failed to fetch optimistic send mutation records", category: .message, error: error)
            return []
        }
    }

    @MainActor
    private func deleteOptimisticSendMutationRecord(messageID: String) {
        for record in fetchOptimisticSendMutationRecords(messageID: messageID) {
            viewContext.delete(record)
        }
    }

    @MainActor
    private func restoreConversationStateForMissingOptimisticMessage(messageID: String) {
        guard let snapshot = fetchOptimisticSendMutationSnapshot(messageID: messageID) else {
            return
        }

        defer {
            deleteOptimisticSendMutationRecord(messageID: messageID)
            saveOptimisticFailureCleanup()
        }

        guard let conversation = resolveConversation(for: snapshot),
              conversation.managedObjectContext != nil,
              !conversation.isDeleted else {
            return
        }

        viewContext.processPendingChanges()

        let remainingMessages = conversation.messages?.filter { !$0.isDeleted } ?? []
        if snapshot.newlyInsertedConversation && remainingMessages.isEmpty {
            viewContext.delete(conversation)
            return
        }

        ConversationRollupUpdater().updateRollups(
            for: conversation,
            myEmail: authSession.userEmail ?? ""
        )
        let hasSupersedingMessage = remainingMessages.contains {
            $0.internalDate > snapshot.createdAt
        }
        snapshot.restoreConversationState(
            conversation,
            restoreRollupFields: !hasSupersedingMessage,
            restoreArchiveState: !hasSupersedingMessage
        )
    }

    @MainActor
    private func resolveConversation(for snapshot: OptimisticSendMutationSnapshot) -> Conversation? {
        if let conversationURI = snapshot.conversationURI,
           let url = URL(string: conversationURI),
           let coordinator = viewContext.persistentStoreCoordinator,
           let objectID = coordinator.managedObjectID(forURIRepresentation: url),
           let conversation = try? viewContext.existingObject(with: objectID) as? Conversation {
            return conversation
        }

        guard let conversationID = snapshot.conversationID else {
            return nil
        }

        let request = Conversation.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
        request.fetchLimit = 1
        request.includesPendingChanges = true

        do {
            return try viewContext.fetch(request).first
        } catch {
            Log.error("Failed to resolve optimistic send conversation", category: .message, error: error)
            return nil
        }
    }
}

private struct OptimisticSendMutationSnapshot {
    let optimisticMessageID: String
    let conversationID: UUID?
    let conversationURI: String?
    let createdAt: Date
    let archivedAt: Date?
    let hidden: Bool
    let displayName: String?
    let lastMessageDate: Date?
    let snippet: String?
    let newlyInsertedConversation: Bool

    @MainActor
    init(optimisticMessageID: String, conversation: Conversation) {
        let newlyInsertedConversation = conversation.isInserted
        let committedValues: [String: Any] = newlyInsertedConversation
            ? [:]
            : conversation.committedValues(
                forKeys: ["archivedAt", "hidden", "displayName", "lastMessageDate", "snippet"]
            )

        self.optimisticMessageID = optimisticMessageID
        self.conversationID = conversation.id
        self.conversationURI = conversation.objectID.uriRepresentation().absoluteString
        self.createdAt = Date()
        self.archivedAt = Self.dateValue(from: committedValues["archivedAt"])
        self.hidden = newlyInsertedConversation
            ? false
            : Self.boolValue(from: committedValues["hidden"], defaultValue: conversation.hidden)
        self.displayName = Self.stringValue(from: committedValues["displayName"])
        self.lastMessageDate = Self.dateValue(from: committedValues["lastMessageDate"])
        self.snippet = Self.stringValue(from: committedValues["snippet"])
        self.newlyInsertedConversation = newlyInsertedConversation
    }

    init(record: OutboundSendMutationRecord) {
        self.optimisticMessageID = record.id
        self.conversationID = record.conversationId
        self.conversationURI = record.conversationURI
        self.createdAt = record.createdAt
        self.archivedAt = record.archivedAt
        self.hidden = record.hidden
        self.displayName = record.displayName
        self.lastMessageDate = record.lastMessageDate
        self.snippet = record.snippet
        self.newlyInsertedConversation = record.newlyInsertedConversation
    }

    func apply(to record: OutboundSendMutationRecord) {
        record.id = optimisticMessageID
        record.conversationId = conversationID
        record.conversationURI = conversationURI
        record.createdAt = createdAt
        record.archivedAt = archivedAt
        record.hidden = hidden
        record.displayName = displayName
        record.lastMessageDate = lastMessageDate
        record.snippet = snippet
        record.newlyInsertedConversation = newlyInsertedConversation
    }

    @MainActor
    func restoreConversationState(
        _ conversation: Conversation,
        restoreRollupFields: Bool,
        restoreArchiveState: Bool
    ) {
        guard !newlyInsertedConversation else { return }

        conversation.displayName = displayName

        if restoreRollupFields {
            conversation.lastMessageDate = lastMessageDate
            conversation.snippet = snippet
        }

        guard restoreArchiveState, !conversation.hasInbox else { return }

        conversation.archivedAt = archivedAt
        conversation.hidden = hidden
    }

    private static func dateValue(from value: Any?) -> Date? {
        value as? Date
    }

    private static func stringValue(from value: Any?) -> String? {
        value as? String
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

private struct OptimisticFailureConversationCleanup {
    let conversation: Conversation?
    let wasInserted: Bool
    private let optimisticMessageDate: Date
    private let optimisticMessageObjectID: NSManagedObjectID
    private let rollbackSnapshot: OptimisticSendMutationSnapshot?

    @MainActor
    init(
        message: Message,
        persistedSnapshot: OptimisticSendMutationSnapshot?
    ) {
        guard let conversation = message.conversation else {
            self.conversation = nil
            self.wasInserted = false
            self.optimisticMessageDate = message.internalDate
            self.optimisticMessageObjectID = message.objectID
            self.rollbackSnapshot = nil
            return
        }

        self.conversation = conversation
        self.wasInserted = persistedSnapshot?.newlyInsertedConversation ?? conversation.isInserted
        self.optimisticMessageDate = message.internalDate
        self.optimisticMessageObjectID = message.objectID
        self.rollbackSnapshot = persistedSnapshot
            ?? OptimisticSendMutationSnapshot(
                optimisticMessageID: message.id,
                conversation: conversation
            )
    }

    @MainActor
    func hasRemainingMessageSupersedingOptimisticMessage(_ messages: [Message]) -> Bool {
        messages.contains { message in
            message.objectID != optimisticMessageObjectID
                && message.internalDate > optimisticMessageDate
        }
    }

    @MainActor
    func restorePreOptimisticConversationStateIfNeeded(
        restoreRollupFields: Bool,
        restoreArchiveState: Bool
    ) {
        guard let conversation else { return }
        rollbackSnapshot?.restoreConversationState(
            conversation,
            restoreRollupFields: restoreRollupFields,
            restoreArchiveState: restoreArchiveState
        )
    }
}
