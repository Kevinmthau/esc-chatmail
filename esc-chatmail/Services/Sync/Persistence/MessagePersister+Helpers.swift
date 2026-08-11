import Foundation
import CoreData

// MARK: - Helper Methods

extension MessagePersister {
    func remoteCommittedSendMutationResolutions(
        for remoteMessageIDs: Set<String>,
        sentMessageIDsByRemoteID: [String: String],
        in context: NSManagedObjectContext
    ) async throws -> [String: RemoteCommittedSendMutationResolution] {
        guard !remoteMessageIDs.isEmpty else { return [:] }

        return try await context.perform {
            let request = OutboundSendMutationRecord.fetchRequest()
            var predicates: [NSPredicate] = [
                NSPredicate(
                    format: "remoteCommittedMessageId IN %@",
                    Array(remoteMessageIDs)
                )
            ]
            let candidateOptimisticIDs = Set(
                sentMessageIDsByRemoteID.values.compactMap(
                    MimeBuilder.optimisticMessageID(from:)
                )
            )
            if !candidateOptimisticIDs.isEmpty {
                predicates.append(
                    NSCompoundPredicate(andPredicateWithSubpredicates: [
                        NSPredicate(
                            format: "remoteCommittedMessageId IN %@",
                            [
                                OutboundSendRemoteState.inFlightMessageID,
                                OutboundSendRemoteState.ambiguousMessageID,
                                OutboundSendRemoteState.notSentMessageID
                            ]
                        ),
                        NSPredicate(
                            format: "id IN %@",
                            Array(candidateOptimisticIDs)
                        )
                    ])
                )
            }
            request.predicate = NSCompoundPredicate(
                orPredicateWithSubpredicates: predicates
            )
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            request.includesPendingChanges = true

            let records = try context.fetch(request)

            var recordsByRemoteMessageID = Dictionary(grouping: records.filter {
                !OutboundSendRemoteState.isLocalMarker($0.remoteCommittedMessageId)
            }) {
                $0.remoteCommittedMessageId ?? ""
            }

            let remoteIDsByRFCMessageID = Dictionary(
                grouping: sentMessageIDsByRemoteID.keys,
                by: { sentMessageIDsByRemoteID[$0] ?? "" }
            )
            for record in records
                where OutboundSendRemoteState.isLocalMarker(record.remoteCommittedMessageId) {
                let expectedMessageID = MimeBuilder.messageId(
                    forOptimisticMessageID: record.id
                )
                for remoteMessageID in remoteIDsByRFCMessageID[expectedMessageID] ?? [] {
                    recordsByRemoteMessageID[remoteMessageID, default: []].append(record)
                }
            }

            let matchedOptimisticIDs = Set(
                recordsByRemoteMessageID.values.flatMap { $0.map(\.id) }
            )
            let optimisticMessagesByID: [String: Message]
            if matchedOptimisticIDs.isEmpty {
                optimisticMessagesByID = [:]
            } else {
                let messageRequest = Message.fetchRequest()
                messageRequest.predicate = NSPredicate(
                    format: "id IN %@",
                    Array(matchedOptimisticIDs)
                )
                messageRequest.relationshipKeyPathsForPrefetching = ["conversation"]
                messageRequest.includesPendingChanges = true
                let optimisticMessages = try context.fetch(messageRequest)
                var messagesByID: [String: Message] = [:]
                for message in optimisticMessages where messagesByID[message.id] == nil {
                    messagesByID[message.id] = message
                }
                optimisticMessagesByID = messagesByID
            }
            var resolutions: [String: RemoteCommittedSendMutationResolution] = [:]
            resolutions.reserveCapacity(recordsByRemoteMessageID.count)

            for (remoteMessageID, matchingRecords) in recordsByRemoteMessageID
                where !remoteMessageID.isEmpty {
                var anchoredListConversationObjectID: NSManagedObjectID?
                var anchoredListId: String?
                var hasUnresolvedExistingAnchor = false

                for record in matchingRecords where !record.newlyInsertedConversation {
                    guard let conversation = Self.resolveMutationConversation(
                        uriString: record.conversationURI,
                        id: record.conversationId,
                        in: context
                    ) else {
                        hasUnresolvedExistingAnchor = true
                        continue
                    }

                    guard conversation.conversationType == .list,
                          let listId = conversation.listId,
                          !listId.isEmpty else {
                        continue
                    }

                    let routingConversation: Conversation
                    if conversation.isRetainedDrainedShell {
                        guard let replacement = Self.recoverableListConversation(
                            listId: listId,
                            excluding: conversation.objectID,
                            in: context
                        ) else {
                            hasUnresolvedExistingAnchor = true
                            continue
                        }
                        routingConversation = replacement
                    } else {
                        routingConversation = conversation
                    }

                    guard anchoredListConversationObjectID == nil else {
                        continue
                    }
                    anchoredListConversationObjectID = routingConversation.objectID
                    anchoredListId = listId
                }

                if hasUnresolvedExistingAnchor &&
                    anchoredListConversationObjectID == nil {
                    Log.warning(
                        "Retaining unresolved existing-conversation send route for a later sync retry",
                        category: .message
                    )
                }

                var supersededOptimisticMessages: [
                    NSManagedObjectID: SupersededOptimisticMessage
                ] = [:]
                for record in matchingRecords {
                    guard let message = optimisticMessagesByID[record.id] else {
                        continue
                    }
                    let wasNewlyInserted =
                        (supersededOptimisticMessages[message.objectID]?
                            .newlyInsertedConversation ?? true)
                        && record.newlyInsertedConversation
                    supersededOptimisticMessages[message.objectID] =
                        SupersededOptimisticMessage(
                            optimisticMessageID: record.id,
                            newlyInsertedConversation: wasNewlyInserted
                        )
                }

                resolutions[remoteMessageID] = RemoteCommittedSendMutationResolution(
                    recordObjectIDs: matchingRecords.map(\.objectID),
                    supersededOptimisticMessages: supersededOptimisticMessages,
                    anchoredListConversationObjectID: anchoredListConversationObjectID,
                    anchoredListId: anchoredListId,
                    shouldConsumeAfterPersistence:
                        anchoredListConversationObjectID != nil || !hasUnresolvedExistingAnchor
                )
            }

            return resolutions
        }
    }

    @discardableResult
    nonisolated func consumeRemoteCommittedSendMutation(
        _ resolution: RemoteCommittedSendMutationResolution?,
        requiresResolvedPersistenceRoute: Bool = true,
        in context: NSManagedObjectContext
    ) -> Set<NSManagedObjectID> {
        guard let resolution,
              !requiresResolvedPersistenceRoute || resolution.shouldConsumeAfterPersistence else {
            return []
        }

        var affectedConversations: [NSManagedObjectID: (Conversation, Bool)] = [:]
        for (messageObjectID, candidate) in
            resolution.supersededOptimisticMessages {
            guard let message = try? context.existingObject(
                with: messageObjectID
            ) as? Message,
            !message.isDeleted else {
                continue
            }
            // API-success reconciliation may rename this exact row to Gmail's
            // ID after resolution captured its objectID. Refreshing with merge
            // preserves the sync update while exposing that durable rename; in
            // that case this is now the real remote row, not a superseded local
            // optimistic row, and deleting it would advance sync with no message.
            context.refresh(message, mergeChanges: true)
            guard !message.isDeleted,
                  message.id == candidate.optimisticMessageID else {
                continue
            }
            if let conversation = message.conversation {
                let existing = affectedConversations[conversation.objectID]
                affectedConversations[conversation.objectID] = (
                    conversation,
                    (existing?.1 ?? true) && candidate.newlyInsertedConversation
                )
            }
            context.delete(message)
        }
        context.processPendingChanges()

        for (_, (conversation, wasNewlyInserted)) in affectedConversations
            where !conversation.isDeleted {
            let remainingMessages = conversation.messages?.filter { !$0.isDeleted } ?? []
            if wasNewlyInserted && remainingMessages.isEmpty {
                context.delete(conversation)
            } else {
                ConversationRollupSnapshot.make(from: Set(remainingMessages)).apply(to: conversation)
            }
        }

        for recordObjectID in resolution.recordObjectIDs {
            guard let record = try? context.existingObject(
                with: recordObjectID
            ) as? OutboundSendMutationRecord,
            !record.isDeleted else {
                continue
            }
            context.delete(record)
        }
        return Set(affectedConversations.keys)
    }

    private nonisolated static func resolveMutationConversation(
        uriString: String?,
        id: UUID?,
        in context: NSManagedObjectContext
    ) -> Conversation? {
        if let uriString,
           let uri = URL(string: uriString),
           let coordinator = context.persistentStoreCoordinator,
           let objectID = coordinator.managedObjectID(forURIRepresentation: uri),
           let conversation = try? context.existingObject(with: objectID) as? Conversation,
           !conversation.isDeleted {
            return conversation
        }

        guard let id else { return nil }

        let request = Conversation.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        request.includesPendingChanges = true
        guard let conversation = try? context.fetch(request).first,
              !conversation.isDeleted else {
            return nil
        }
        return conversation
    }

    private nonisolated static func recoverableListConversation(
        listId: String,
        excluding excludedObjectID: NSManagedObjectID,
        in context: NSManagedObjectContext
    ) -> Conversation? {
        let request = Conversation.fetchRequest()
        request.predicate = NSPredicate(format: "listId == %@", listId)
        request.includesPendingChanges = true

        guard let conversations = try? context.fetch(request) else {
            return nil
        }
        let candidates = conversations.filter {
            $0.objectID != excludedObjectID &&
                !$0.isDeleted &&
                !$0.isRetainedDrainedShell &&
                $0.conversationType == .list
        }
        return ConversationRoutingPolicy().selectParticipantHashConversation(
            from: candidates,
            reactivateArchivedIfNeeded: true
        )
    }

    /// Removes any local row for an excluded-mailbox message.
    /// - Returns: false when the lookup/delete failed — the local row may
    ///   still exist, so the message must not be reported as cleanly excluded.
    @discardableResult
    func deleteExistingMessageIfPresent(
        id: String,
        modificationTransaction: ModificationTracker.Transaction?,
        remoteCommittedSendMutation: RemoteCommittedSendMutationResolution? = nil,
        in context: NSManagedObjectContext
    ) async -> Bool {
        let (succeeded, modifiedConversationIDs): (Bool, Set<NSManagedObjectID>) = await context.perform {
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id(id)
            request.fetchLimit = 1
            request.relationshipKeyPathsForPrefetching = ["conversation"]

            do {
                var modifiedConversationIDs = Set<NSManagedObjectID>()
                if let message = try context.fetch(request).first {
                    if let conversationID = message.conversation?.objectID {
                        modifiedConversationIDs.insert(conversationID)
                    }
                    context.delete(message)
                }

                // An excluded remote echo has no message to route, so a missing
                // legacy list anchor cannot justify retaining its optimistic
                // graph. Delete the exact remote row (if any), superseded local
                // row/conversation, and mutation record in this one context
                // transaction; the caller's cursor advances in the same save.
                modifiedConversationIDs.formUnion(
                    self.consumeRemoteCommittedSendMutation(
                        remoteCommittedSendMutation,
                        requiresResolvedPersistenceRoute: false,
                        in: context
                    )
                )
                return (true, modifiedConversationIDs)
            } catch {
                Log.error("Failed to delete excluded mailbox message \(id)", category: .coreData, error: error)
                return (false, [])
            }
        }

        if !modifiedConversationIDs.isEmpty {
            await ModificationTracker.shared.trackModifiedConversations(
                modifiedConversationIDs,
                in: modificationTransaction
            )
        }
        return succeeded
    }

    /// Creates an attachment entity using AttachmentFactory.
    nonisolated func createAttachment(
        _ info: AttachmentInfo,
        for message: Message,
        in context: NSManagedObjectContext
    ) {
        do {
            let attachment = try AttachmentFactory.create(from: info, for: message, in: context)

            if let inlineData = info.inlineData {
                let didPersistInlineData = persistInlineAttachmentData(
                    inlineData,
                    info: info,
                    attachment: attachment,
                    messageId: message.id
                )
                if !didPersistInlineData {
                    context.delete(attachment)
                    Log.warning("Dropping inline attachment for message \(message.id) due to local persistence failure", category: .attachment)
                }
            }
        } catch {
            Log.error("Failed to create attachment for message \(message.id): \(error)", category: .coreData)
        }
    }

    func scheduleInlineCIDPrefetchIfNeeded(
        for processedMessage: ProcessedMessage,
        in context: NSManagedObjectContext
    ) async {
        let request = InlineCIDAttachmentPrefetchRequest(
            messageId: processedMessage.id,
            contentIDs: processedMessage.inlineCIDPrefetchContentIDs,
            attachmentIDs: processedMessage.inlineCIDPrefetchAttachmentIDs
        )
        guard !request.isEmpty else { return }

        let scheduler = inlineCIDPrefetchScheduler
        await context.perform {
            scheduler(request, context)
        }
    }

    nonisolated func persistInlineAttachmentData(
        _ inlineData: Data,
        info: AttachmentInfo,
        attachment: Attachment,
        messageId: String
    ) -> Bool {
        AttachmentPaths.setupDirectories()

        guard let attachmentId = attachment.id, !attachmentId.isEmpty else {
            return false
        }

        let filenameExt = (info.filename as NSString).pathExtension.lowercased()
        let ext = filenameExt.isEmpty ? AttachmentPaths.fileExtension(for: info.mimeType) : filenameExt
        let originalPath = AttachmentPaths.originalPath(
            messageId: messageId,
            attachmentId: attachmentId,
            ext: ext
        )

        guard AttachmentPaths.saveData(inlineData, to: originalPath) else {
            return false
        }

        attachment.localURL = originalPath
        attachment.byteSize = Int64(max(info.size, inlineData.count))

        if info.mimeType.hasPrefix("image/"),
           let dimensions = ImageProcessor.getImageDimensions(from: inlineData) {
            attachment.width = Int16(clamping: Int(dimensions.width.rounded()))
            attachment.height = Int16(clamping: Int(dimensions.height.rounded()))
        }

        if info.mimeType == "application/pdf",
           let pageCount = ImageProcessor.getPDFPageCount(from: inlineData) {
            attachment.pageCount = Int16(clamping: pageCount)
        }

        var savedPreviewPath: String?
        if let thumbnailData = ImageProcessor.generateThumbnail(from: inlineData, mimeType: info.mimeType) {
            let previewPath = AttachmentPaths.previewPath(
                messageId: messageId,
                attachmentId: attachmentId
            )
            if AttachmentPaths.saveData(thumbnailData, to: previewPath) {
                savedPreviewPath = previewPath
            }
        }
        attachment.previewURL = savedPreviewPath

        attachment.state = .downloaded
        attachment.lastDownloadFailedAt = nil
        return true
    }

    /// Applies list-critical rollup fields immediately when a new message is created.
    /// This allows the conversation row (blue dot + preview text) to update before the
    /// full rollup phase runs later in sync.
    nonisolated func applyFastConversationListUpdateForNewMessage(
        _ message: Message,
        in conversation: Conversation,
        hasInboxLabel: Bool
    ) {
        // Keep latest message preview/date current so row text updates immediately.
        if let existingLastDate = conversation.lastMessageDate {
            if message.internalDate >= existingLastDate {
                conversation.lastMessageDate = message.internalDate
                if let previewText = MessagePreviewText.nonEmpty(message.conversationPreviewText) {
                    conversation.snippet = previewText
                }
            }
        } else {
            conversation.lastMessageDate = message.internalDate
            if let previewText = MessagePreviewText.nonEmpty(message.conversationPreviewText) {
                conversation.snippet = previewText
            }
        }

        guard hasInboxLabel else { return }

        conversation.hasInbox = true
        if message.isUnread {
            // A sole first message was already counted by the creation-time
            // ConversationInboxSeed; assign instead of incrementing so the
            // fast path stays idempotent with that seed.
            let isOnlyMessage = (conversation.messages?.count ?? 0) <= 1
            conversation.inboxUnreadCount = isOnlyMessage
                ? 1
                : min(Int32.max, conversation.inboxUnreadCount + 1)
        }

        if let existingLatestInboxDate = conversation.latestInboxDate {
            if message.internalDate > existingLatestInboxDate {
                conversation.latestInboxDate = message.internalDate
            }
        } else {
            conversation.latestInboxDate = message.internalDate
        }

        // New inbox mail should immediately reactivate hidden/archived threads.
        ConversationRoutingPolicy().reactivateArchivedConversationIfNeeded(
            conversation,
            shouldReactivate: true
        )
    }

    /// Applies list-critical rollup fields immediately when an existing message is updated.
    /// Falls back to a scoped inbox recomputation when INBOX membership changes.
    nonisolated func applyFastConversationListUpdateForExistingMessage(
        _ message: Message,
        in conversation: Conversation,
        previousHadInboxLabel: Bool,
        previousWasUnread: Bool,
        currentHasInboxLabel: Bool,
        currentIsUnread: Bool
    ) {
        let previousUnreadInInbox = previousHadInboxLabel && previousWasUnread
        let currentUnreadInInbox = currentHasInboxLabel && currentIsUnread

        if previousUnreadInInbox != currentUnreadInInbox {
            if currentUnreadInInbox {
                conversation.inboxUnreadCount = min(Int32.max, conversation.inboxUnreadCount + 1)
            } else {
                conversation.inboxUnreadCount = max(0, conversation.inboxUnreadCount - 1)
            }
        }

        if currentHasInboxLabel {
            conversation.hasInbox = true
            if let existingLatestInboxDate = conversation.latestInboxDate {
                if message.internalDate > existingLatestInboxDate {
                    conversation.latestInboxDate = message.internalDate
                }
            } else {
                conversation.latestInboxDate = message.internalDate
            }

            ConversationRoutingPolicy().reactivateArchivedConversationIfNeeded(
                conversation,
                shouldReactivate: true
            )
        } else if previousHadInboxLabel {
            // This message left INBOX; recompute inbox-only indicators for correctness.
            refreshConversationInboxIndicators(conversation)
        }

        if let existingLastDate = conversation.lastMessageDate {
            if message.internalDate >= existingLastDate {
                conversation.lastMessageDate = message.internalDate
                if let previewText = MessagePreviewText.nonEmpty(message.conversationPreviewText) {
                    conversation.snippet = previewText
                }
            }
        } else {
            conversation.lastMessageDate = message.internalDate
            if let previewText = MessagePreviewText.nonEmpty(message.conversationPreviewText) {
                conversation.snippet = previewText
            }
        }
    }

    /// Recomputes inbox-specific conversation indicators from the conversation's message set.
    /// Note: For best performance, prefetch "messages" and "messages.labels" on the
    /// conversation's fetch request via relationshipKeyPathsForPrefetching before calling this.
    nonisolated func refreshConversationInboxIndicators(_ conversation: Conversation) {
        // Prefetch labels for all messages to avoid N individual faults
        if let context = conversation.managedObjectContext, let messages = conversation.messages, !messages.isEmpty {
            let messageIDs = messages.compactMap { $0.objectID }
            let prefetchRequest = Message.fetchRequest()
            prefetchRequest.predicate = NSPredicate(format: "SELF IN %@", messageIDs)
            prefetchRequest.relationshipKeyPathsForPrefetching = ["labels"]
            _ = try? context.fetch(prefetchRequest)
        }

        guard let messages = conversation.messages else {
            conversation.hasInbox = false
            conversation.inboxUnreadCount = 0
            conversation.latestInboxDate = nil
            return
        }

        var hasInbox = false
        var unreadCount: Int32 = 0
        var latestInboxDate: Date?

        for message in messages {
            let isInbox = message.labels?.contains(where: { $0.id == "INBOX" }) ?? false
            guard isInbox else { continue }

            hasInbox = true
            if message.isUnread {
                unreadCount = min(Int32.max, unreadCount + 1)
            }
            if let currentLatestInboxDate = latestInboxDate {
                if message.internalDate > currentLatestInboxDate {
                    latestInboxDate = message.internalDate
                }
            } else {
                latestInboxDate = message.internalDate
            }
        }

        conversation.hasInbox = hasInbox
        conversation.inboxUnreadCount = unreadCount
        conversation.latestInboxDate = latestInboxDate
    }
}
