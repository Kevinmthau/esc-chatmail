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
        try await createOptimisticMessage(
            to: recipients,
            body: body,
            subject: subject,
            threadId: threadId,
            attachments: attachments,
            chatPreviewText: optimisticChatPreviewText(from: body),
            optimisticConversation: optimisticConversation
        )
    }

    /// Creates an optimistic local message with an explicit chat preview.
    /// The stored body stays as the full send body for full-message viewing.
    @MainActor
    func createOptimisticMessage(
        to recipients: [String],
        body: String,
        subject: String? = nil,
        threadId: String? = nil,
        attachments: [OutboundMessageRequest.AttachmentContext] = [],
        chatPreviewText: String?,
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
            guard conversation.managedObjectContext === viewContext,
                  !conversation.isDeleted,
                  !conversation.isRetainedDrainedShell else {
                Log.warning(
                    "Blocked optimistic reply insertion into an invalid conversation anchor",
                    category: .message
                )
                throw SendError.replyTargetUnavailable
            }
        } else {
            // Use the same alias set the sync router excludes so the optimistic
            // conversation and the synced-back copy of this send hash identically.
            // getAliases(from:) falls back to Core Data when the cache is cold
            // (fresh launch, post-invalidate) — a cached-only read would hash
            // without self-exclusion exactly when parity is load-bearing.
            let myAliases = await AliasManager.shared.getAliases(from: viewContext)
            conversation = try findOrCreateOptimisticConversation(
                participantHash: optimisticConversation?.participantHashValue
                    ?? makeOptimisticParticipantHash(from: recipients, myAliases: myAliases),
                recipients: recipients,
                myAliases: myAliases,
                in: viewContext
            )
        }

        let message = Message(context: viewContext)
        message.id = messageId
        message.isFromMe = true
        message.internalDate = Date()
        message.snippet = snippet
        message.cleanedSnippet = cleanedSnippet
        message.chatPreviewText = optimisticChatPreviewText(from: chatPreviewText)
        message.bodyText = body
        message.gmThreadId = gmThreadId
        message.subject = subject
        // Anchored list replies must carry the same durable identity as their
        // conversation immediately. Otherwise selecting the optimistic bubble
        // for a follow-up reply fails the exact-list safety check until sync
        // happens to refetch the sent message.
        message.listId = conversation.listId
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

    private nonisolated func optimisticChatPreviewText(from text: String?) -> String? {
        guard let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedText.isEmpty else {
            return nil
        }

        return trimmedText
    }

    @MainActor
    func remoteCommittedSendResult(optimisticMessageID: String) -> SendResult? {
        fetchFreshOptimisticSendMutationSnapshot(messageID: optimisticMessageID)?.remoteCommittedResult
    }

    @MainActor
    func recordRemoteCommittedSend(
        optimisticMessageID: String,
        result: SendResult
    ) throws {
        guard let coordinator = viewContext.persistentStoreCoordinator else {
            throw SendError.optimisticCreationFailed
        }

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        try context.performAndWait {
            let record = Self.fetchOptimisticSendMutationRecords(
                messageID: optimisticMessageID,
                in: context
            ).first ?? OutboundSendMutationRecord(context: context)

            if record.isInserted {
                Self.initializeFallbackOptimisticSendMutationRecord(
                    record,
                    optimisticMessageID: optimisticMessageID
                )
            }

            record.remoteCommittedMessageId = result.messageId
            record.remoteCommittedThreadId = result.threadId

            if context.hasChanges {
                try context.save()
            }
        }
    }

    @MainActor
    @discardableResult
    func reconcileRemoteCommittedSend(
        optimisticMessageID: String,
        result: SendResult
    ) throws -> Bool {
        if let remoteMessage = fetchMessageSync(byID: result.messageId) {
            if let snapshot = fetchFreshOptimisticSendMutationSnapshot(
                messageID: optimisticMessageID
            ), !snapshot.newlyInsertedConversation {
                guard let recordedConversation = resolveConversation(for: snapshot) else {
                    Log.info(
                        "Retaining remote committed send \(optimisticMessageID) until its existing conversation route resolves",
                        category: .message
                    )
                    return false
                }
                if recordedConversation.conversationType == .list {
                    guard let anchor = resolveAnchoredListConversation(for: snapshot) else {
                        Log.info(
                            "Retaining remote committed list send \(optimisticMessageID) until a reusable list conversation resolves",
                            category: .message
                        )
                        return false
                    }
                    rehomeRemoteCommittedMessage(
                        remoteMessage,
                        to: anchor.conversation,
                        listId: anchor.listId
                    )
                }
            }
            deleteSupersededOptimisticMessageIfNeeded(messageID: optimisticMessageID)
            try deleteOptimisticSendMutationRecordAndSave(messageID: optimisticMessageID)
            return true
        }

        guard let message = fetchMessageSync(byID: optimisticMessageID) else {
            if let snapshot = fetchFreshOptimisticSendMutationSnapshot(
                messageID: optimisticMessageID
            ), !snapshot.newlyInsertedConversation {
                Log.info(
                    "Retaining remote committed anchored send \(optimisticMessageID) for sync routing",
                    category: .message
                )
                return false
            }

            Log.warning(
                "Remote committed send \(optimisticMessageID) has no local optimistic message; clearing mutation record and relying on sync",
                category: .message
            )
            try deleteOptimisticSendMutationRecordAndSave(messageID: optimisticMessageID)
            return false
        }

        let originalMessageID = message.id
        let originalThreadID = message.gmThreadId
        let localAttachments = message.attachmentsArray.filter(\.isLocalAttachment)
        let originalAttachmentStates = localAttachments.map { ($0, $0.state) }

        message.id = result.messageId
        message.gmThreadId = result.threadId
        for attachment in localAttachments {
            attachment.state = .uploaded
        }

        do {
            if viewContext.hasChanges {
                try viewContext.save()
            }
        } catch {
            message.id = originalMessageID
            message.gmThreadId = originalThreadID
            for (attachment, state) in originalAttachmentStates {
                attachment.state = state
            }
            Log.error("Failed to reconcile optimistic message with Gmail ID", category: .message, error: error)
            throw error
        }

        do {
            try deleteOptimisticSendMutationRecordAndSave(messageID: optimisticMessageID)
        } catch {
            Log.error("Failed to clear reconciled optimistic send mutation record", category: .message, error: error)
        }

        return true
    }

    @MainActor
    private func deleteSupersededOptimisticMessageIfNeeded(messageID: String) {
        guard let message = fetchMessageSync(byID: messageID) else {
            return
        }

        let mutationSnapshot = fetchFreshOptimisticSendMutationSnapshot(messageID: messageID)
        let conversation = message.conversation
        let wasInsertedConversation = mutationSnapshot?.newlyInsertedConversation ?? conversation?.isInserted ?? false
        viewContext.delete(message)
        viewContext.processPendingChanges()

        guard let conversation,
              conversation.managedObjectContext != nil,
              !conversation.isDeleted else {
            return
        }

        let remainingMessages = conversation.messages?.filter { !$0.isDeleted } ?? []
        if wasInsertedConversation && remainingMessages.isEmpty {
            viewContext.delete(conversation)
            return
        }

        ConversationRollupUpdater().updateRollups(
            for: conversation,
            myEmail: authSession.userEmail ?? ""
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
        do {
            try reconcileRemoteCommittedSend(optimisticMessageID: message.id, result: result)
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
        for attachment in message.attachmentsArray {
            attachment.message = nil
        }
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
        myAliases: Set<String>,
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
            existingConversation.displayName = optimisticConversationDisplayName(for: recipients)
            return existingConversation
        }

        // Build the creation identity through the same recipient-list pipeline
        // that produced the lookup hash — deriving it from synthetic To headers
        // would let the created conversation's hash diverge from the hash the
        // fetch above just missed on.
        let setIdentity = makeRecipientParticipantSetIdentity(recipients: recipients, myAliases: myAliases)
            ?? makeParticipantSetIdentity(normalizedEmails: [], myAliases: myAliases)
        let conversation = try ConversationFactory.create(
            for: makeConversationIdentity(from: setIdentity),
            initialLastMessageDate: Date(),
            in: context
        )

        // Update display name for sent messages
        conversation.displayName = optimisticConversationDisplayName(for: recipients)

        return conversation
    }

    @MainActor
    private func optimisticConversationDisplayName(for recipients: [String]) -> String {
        let myEmailKey = EmailNormalizer.normalize(authSession.userEmail ?? "")
        let nonSelfRecipients = recipients.filter { recipient in
            EmailNormalizer.normalize(recipient) != myEmailKey
        }
        return PersonDisplayNameResolver.conversationDisplayName(
            realNames: [],
            totalParticipantCount: nonSelfRecipients.count,
            fallback: nil,
            participantEmails: nonSelfRecipients
        )
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

    private func makeOptimisticParticipantHash(from recipients: [String], myAliases: Set<String>) -> String {
        let identity = makeRecipientParticipantSetIdentity(recipients: recipients, myAliases: myAliases)
            ?? makeParticipantSetIdentity(normalizedEmails: [], myAliases: myAliases)
        return identity.participantHash
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
        let snapshots = fetchAllOptimisticSendMutationRecords()
            .map(OptimisticSendMutationSnapshot.init(record:))
        guard !snapshots.isEmpty else { return false }

        Log.info("Reconciling \(snapshots.count) abandoned optimistic send mutation(s)", category: .message)
        for snapshot in snapshots {
            if let remoteCommittedResult = snapshot.remoteCommittedResult {
                do {
                    try reconcileRemoteCommittedSend(
                        optimisticMessageID: snapshot.optimisticMessageID,
                        result: remoteCommittedResult
                    )
                } catch {
                    Log.error(
                        "Failed to reconcile remote committed optimistic send \(snapshot.optimisticMessageID)",
                        category: .message,
                        error: error
                    )
                }
            } else {
                handleFailedOptimisticMessage(
                    byID: snapshot.optimisticMessageID,
                    fallbackAttachmentReferences: []
                )
            }
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
            let record = Self.fetchOptimisticSendMutationRecords(
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
    private func fetchFreshOptimisticSendMutationSnapshot(messageID: String) -> OptimisticSendMutationSnapshot? {
        guard let coordinator = viewContext.persistentStoreCoordinator else {
            return nil
        }

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        var snapshot: OptimisticSendMutationSnapshot?
        context.performAndWait {
            snapshot = Self.fetchOptimisticSendMutationRecords(
                messageID: messageID,
                in: context
            ).first.map(OptimisticSendMutationSnapshot.init(record:))
        }
        return snapshot
    }

    @MainActor
    private func fetchOptimisticSendMutationRecords(messageID: String) -> [OutboundSendMutationRecord] {
        Self.fetchOptimisticSendMutationRecords(messageID: messageID, in: viewContext)
    }

    private static func fetchOptimisticSendMutationRecords(
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
    private func deleteOptimisticSendMutationRecordAndSave(messageID: String) throws {
        deleteOptimisticSendMutationRecord(messageID: messageID)
        if viewContext.hasChanges {
            try viewContext.save()
        }
    }

    private static func initializeFallbackOptimisticSendMutationRecord(
        _ record: OutboundSendMutationRecord,
        optimisticMessageID: String
    ) {
        record.id = optimisticMessageID
        record.createdAt = Date()
        record.hidden = false
        record.newlyInsertedConversation = false
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

    @MainActor
    private func resolveAnchoredListConversation(
        for snapshot: OptimisticSendMutationSnapshot
    ) -> (conversation: Conversation, listId: String)? {
        guard !snapshot.newlyInsertedConversation,
              let recordedConversation = resolveConversation(for: snapshot),
              recordedConversation.managedObjectContext != nil,
              !recordedConversation.isDeleted,
              recordedConversation.conversationType == .list,
              let listId = recordedConversation.listId,
              !listId.isEmpty else {
            return nil
        }

        let conversation: Conversation
        if recordedConversation.isRetainedDrainedShell {
            guard let replacement = recoverableListConversation(
                listId: listId,
                excluding: recordedConversation.objectID
            ) else {
                return nil
            }
            conversation = replacement
        } else {
            conversation = recordedConversation
        }

        return (conversation, listId)
    }

    @MainActor
    private func recoverableListConversation(
        listId: String,
        excluding excludedObjectID: NSManagedObjectID
    ) -> Conversation? {
        let request = Conversation.fetchRequest()
        request.predicate = NSPredicate(
            format: "listId == %@ AND SELF != %@",
            listId,
            excludedObjectID
        )
        request.includesPendingChanges = true

        guard let conversations = try? viewContext.fetch(request) else {
            return nil
        }
        let candidates = conversations.filter {
            !$0.isDeleted &&
                !$0.isRetainedDrainedShell &&
                $0.conversationType == .list
        }
        return ConversationRoutingPolicy().selectParticipantHashConversation(
            from: candidates,
            reactivateArchivedIfNeeded: true
        )
    }

    @MainActor
    private func rehomeRemoteCommittedMessage(
        _ message: Message,
        to conversation: Conversation,
        listId: String
    ) {
        let source = message.conversation
        guard source?.objectID != conversation.objectID || message.listId != listId else {
            return
        }

        message.conversation = conversation
        message.listId = listId
        viewContext.processPendingChanges()

        let rollupUpdater = ConversationRollupUpdater()
        if let source, source != conversation {
            let sourceWillBeEmpty =
                source.mutableSetValue(forKey: "messages").count == 0
            if sourceWillBeEmpty {
                conversation.pinned = conversation.pinned || source.pinned
                conversation.muted = conversation.muted || source.muted
            }
            rollupUpdater.updateRollups(
                for: source,
                myEmail: authSession.userEmail ?? ""
            )
        }
        rollupUpdater.updateRollups(
            for: conversation,
            myEmail: authSession.userEmail ?? ""
        )
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
    let remoteCommittedMessageId: String?
    let remoteCommittedThreadId: String?

    var remoteCommittedResult: GmailSendService.SendResult? {
        guard let remoteCommittedMessageId,
              let remoteCommittedThreadId,
              !remoteCommittedMessageId.isEmpty,
              !remoteCommittedThreadId.isEmpty else {
            return nil
        }

        return GmailSendService.SendResult(
            messageId: remoteCommittedMessageId,
            threadId: remoteCommittedThreadId
        )
    }

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
        self.remoteCommittedMessageId = nil
        self.remoteCommittedThreadId = nil
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
        self.remoteCommittedMessageId = record.remoteCommittedMessageId
        self.remoteCommittedThreadId = record.remoteCommittedThreadId
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
        record.remoteCommittedMessageId = remoteCommittedMessageId
        record.remoteCommittedThreadId = remoteCommittedThreadId
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
