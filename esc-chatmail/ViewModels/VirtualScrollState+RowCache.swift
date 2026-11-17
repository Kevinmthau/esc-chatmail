import Foundation
import CoreData

// MARK: - Row cache and page loading

extension VirtualScrollState {
    func setMessageWindow(_ window: MessageWindow) {
        messageWindow = window
        resolvedRowsByAbsoluteIndex.removeAll()
        localSendAppendedMessageIDs.removeAll()

        let allowedIDs = Set(window.messageIDs)
        resolvedRowsByID = resolvedRowsByID.filter { allowedIDs.contains($0.key) }
    }

    func invalidateCachedRows(for objectIDs: Set<NSManagedObjectID>) {
        guard !objectIDs.isEmpty else { return }

        for objectID in objectIDs {
            resolvedRowsByID.removeValue(forKey: objectID)
        }

        resolvedRowsByAbsoluteIndex = resolvedRowsByAbsoluteIndex.filter { _, row in
            !objectIDs.contains(row.objectID)
        }
    }

    // The original bug was caused by fetching `Message` instances in a background
    // context and then storing those managed objects on `@MainActor` state. We now
    // re-resolve background-fetched object IDs on the viewContext before mapping
    // them into lightweight row snapshots for SwiftUI.
    func resolveRowsOnViewContextThrowing(
        for messageIDs: [NSManagedObjectID]
    ) throws -> [ChatMessageRowModel] {
        guard !messageIDs.isEmpty else { return [] }

        let request = NSFetchRequest<Message>(entityName: "Message")
        request.predicate = NSPredicate(format: "SELF IN %@", messageIDs)
        request.fetchBatchSize = messageIDs.count
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person", "attachments"]

        let fetchedMessages = try viewContext.fetch(request)
        let fetchedRows = ChatMessageRowModelMapper.map(fetchedMessages)
        let resolvedRows: [NSManagedObjectID: ChatMessageRowModel] = Dictionary(
            uniqueKeysWithValues: zip(fetchedMessages, fetchedRows).compactMap { message, row in
                guard !message.isDeleted else { return nil }
                return (message.objectID, row)
            }
        )

        for objectID in messageIDs {
            if let row = resolvedRows[objectID] {
                resolvedRowsByID[objectID] = row
            } else {
                resolvedRowsByID.removeValue(forKey: objectID)
            }
        }

        return messageIDs.compactMap { resolvedRows[$0] }
    }

    /// `resolveRowsOnViewContextThrowing` for only the IDs whose cached rows
    /// are kept fresh: those of the current window, which
    /// `handleViewContextChange` evicts on view-context updates, refreshes
    /// and deletions of the message or its attachments (the same rows the
    /// covered-window path renders from `resolveCachedRows`). Anything else
    /// in the cache (rows a superseded preload resolved after the window
    /// moved on) is re-mapped, because nothing evicts it.
    func resolveRowsReusingCacheThrowing(
        for messageIDs: [NSManagedObjectID]
    ) throws -> [ChatMessageRowModel] {
        let trustedMessageIDs = Set(messageWindow?.messageIDs ?? [])
        let uncachedMessageIDs = messageIDs.filter {
            !trustedMessageIDs.contains($0) || resolvedRowsByID[$0] == nil
        }
        if !uncachedMessageIDs.isEmpty {
            _ = try resolveRowsOnViewContextThrowing(for: uncachedMessageIDs)
        }
        return messageIDs.compactMap { resolvedRowsByID[$0] }
    }

    func row(atAbsoluteIndex index: Int) -> ChatMessageRowModel? {
        guard let window = messageWindow,
              window.contains(index: index) else {
            return nil
        }

        let relativeIndex = index - window.startIndex
        guard relativeIndex >= 0, relativeIndex < window.messageIDs.count else {
            return nil
        }

        return resolveCachedRow(for: window.messageIDs[relativeIndex])
    }

    func rowForGrouping(atAbsoluteIndex index: Int) -> ChatMessageRowModel? {
        if let row = row(atAbsoluteIndex: index) {
            return row
        }

        guard index >= 0, index < totalMessageCount else { return nil }
        if let cached = resolvedRowsByAbsoluteIndex[index] {
            return cached
        }
        guard let conversationUUID = UUID(uuidString: conversationId) else { return nil }

        let request = NSFetchRequest<Message>(entityName: "Message")
        // `currentConversationObjectID` caches permanent IDs only, so an
        // unsaved conversation keeps the UUID form.
        if let conversationObjectID = currentConversationObjectID(),
           !conversationObjectID.isTemporaryID {
            request.predicate = MessagePredicates.visibleInChat(conversationObjectID: conversationObjectID)
        } else {
            request.predicate = MessagePredicates.visibleInChat(conversationId: conversationUUID)
        }
        request.sortDescriptors = Self.messageSortDescriptors
        request.fetchOffset = index
        request.fetchLimit = 1
        request.fetchBatchSize = 1
        request.includesPendingChanges = true
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person", "attachments"]

        guard let message = try? viewContext.fetch(request).first,
              !message.isDeleted else {
            return nil
        }

        let row = ChatMessageRowModelMapper.map(message)
        resolvedRowsByID[message.objectID] = row
        resolvedRowsByAbsoluteIndex[index] = row
        return row
    }

    func resolveCachedRows(for messageIDs: [NSManagedObjectID]) -> [ChatMessageRowModel] {
        let uncachedMessageIDs = messageIDs.filter {
            resolvedRowsByID[$0] == nil
        }
        if !uncachedMessageIDs.isEmpty {
            do {
                _ = try resolveRowsOnViewContextThrowing(
                    for: uncachedMessageIDs
                )
            } catch {
                Log.error(
                    "Failed to batch-resolve cached chat rows",
                    category: .coreData,
                    error: error
                )
                // Preserve the prior best-effort behavior on an exceptional
                // batch failure; the normal scroll path remains batched.
                for objectID in uncachedMessageIDs {
                    _ = resolveCachedRow(for: objectID)
                }
            }
        }

        return messageIDs.compactMap { resolvedRowsByID[$0] }
    }

    func resolveCachedRow(for objectID: NSManagedObjectID) -> ChatMessageRowModel? {
        if let cached = resolvedRowsByID[objectID] {
            return cached
        }

        if let registered = viewContext.registeredObject(for: objectID) as? Message,
           !registered.isDeleted {
            let row = ChatMessageRowModelMapper.map(registered)
            resolvedRowsByID[objectID] = row
            return row
        }

        do {
            guard let resolved = try viewContext.existingObject(with: objectID) as? Message,
                  !resolved.isDeleted else {
                resolvedRowsByID.removeValue(forKey: objectID)
                return nil
            }

            let row = ChatMessageRowModelMapper.map(resolved)
            resolvedRowsByID[objectID] = row
            return row
        } catch {
            resolvedRowsByID.removeValue(forKey: objectID)
            return nil
        }
    }

    nonisolated static func loadMessagePage(
        conversationId: String,
        range: Range<Int>,
        in context: NSManagedObjectContext
    ) async -> VirtualScrollMessagePage {
        await loadMessagePage(
            conversationId: conversationId,
            range: range,
            conversationObjectID: nil,
            in: context
        )
    }

    /// `conversationObjectID` is the conversation's permanent objectID where
    /// the caller already has it (the scroll state keeps the one its first
    /// load resolved). With it the load does not look the conversation up.
    nonisolated static func loadMessagePage(
        conversationId: String,
        range: Range<Int>,
        conversationObjectID: NSManagedObjectID?,
        in context: NSManagedObjectContext
    ) async -> VirtualScrollMessagePage {
        guard let conversationUUID = UUID(uuidString: conversationId) else {
            return VirtualScrollMessagePage(messageIDs: [], totalCount: 0)
        }

        return await context.perform {
            do {
                // This load reads the store only, and a conversation the
                // store has no row for has no stored messages either.
                guard let transcript = try transcriptPredicate(
                    conversationUUID: conversationUUID,
                    knownConversationObjectID: conversationObjectID,
                    includesPendingChanges: false,
                    in: context
                ) else {
                    return VirtualScrollMessagePage(messageIDs: [], totalCount: 0)
                }
                let predicate = transcript.predicate

                let messageIDs: [NSManagedObjectID]
                if range.isEmpty {
                    messageIDs = []
                } else {
                    let request = NSFetchRequest<NSManagedObjectID>(entityName: "Message")
                    request.predicate = predicate
                    request.sortDescriptors = messageSortDescriptors
                    request.fetchOffset = range.lowerBound
                    request.fetchLimit = range.count
                    request.fetchBatchSize = 20
                    request.includesPendingChanges = false
                    request.resultType = .managedObjectIDResultType
                    messageIDs = try context.fetch(request)
                }

                // Keep count() on the background context so window sizing stays cheap and
                // the main actor only resolves the IDs it actually needs to render.
                let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
                countRequest.predicate = predicate
                countRequest.includesPendingChanges = false
                let totalCount = try context.count(for: countRequest)

                return VirtualScrollMessagePage(
                    messageIDs: messageIDs,
                    totalCount: totalCount,
                    conversationObjectID: transcript.conversationObjectID
                )
            } catch {
                return VirtualScrollMessagePage(
                    messageIDs: [],
                    totalCount: 0,
                    fetchErrorDescription: error.localizedDescription
                )
            }
        }
    }

    nonisolated static func loadPendingMessagePage(
        conversationId: String,
        range: Range<Int>,
        conversationObjectID: NSManagedObjectID? = nil,
        in context: NSManagedObjectContext
    ) async -> VirtualScrollMessagePage {
        guard let conversationUUID = UUID(uuidString: conversationId) else {
            return VirtualScrollMessagePage(messageIDs: [], totalCount: 0)
        }

        return await context.perform {
            do {
                // With pending changes in play, a conversation this lookup
                // cannot name (one deleted but not yet saved, say) keeps the
                // UUID form and whatever it selected before.
                let transcript = try transcriptPredicate(
                    conversationUUID: conversationUUID,
                    knownConversationObjectID: conversationObjectID,
                    includesPendingChanges: true,
                    in: context
                )
                let predicate = transcript?.predicate
                    ?? MessagePredicates.visibleInChat(conversationId: conversationUUID)

                let messages: [Message]
                if range.isEmpty {
                    messages = []
                } else {
                    let request = NSFetchRequest<Message>(entityName: "Message")
                    request.predicate = predicate
                    request.sortDescriptors = messageSortDescriptors
                    request.fetchOffset = range.lowerBound
                    request.fetchLimit = range.count
                    request.fetchBatchSize = 20
                    request.includesPendingChanges = true
                    messages = try context.fetch(request)
                }

                let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
                countRequest.predicate = predicate
                countRequest.includesPendingChanges = true
                let totalCount = try context.count(for: countRequest)

                return VirtualScrollMessagePage(
                    messageIDs: messages.map(\.objectID),
                    totalCount: totalCount,
                    conversationObjectID: transcript?.conversationObjectID
                )
            } catch {
                return VirtualScrollMessagePage(
                    messageIDs: [],
                    totalCount: 0,
                    fetchErrorDescription: error.localizedDescription
                )
            }
        }
    }

    /// The transcript's predicate for the conversation with this UUID, with
    /// the conversation's permanent objectID where it has one, or nil when
    /// `context` finds no such conversation. Call inside `context.perform`.
    ///
    /// The conversation is looked up by its UUID, unless the caller hands in
    /// the permanent objectID an earlier load resolved
    /// (`knownConversationObjectID`): the lookup compares a UUID no index
    /// covers, and a chat that pages as it scrolls made it at every page.
    /// The messages are then asked for by the objectID, which SQLite answers
    /// from the conversation's own message index whatever statistics the
    /// store has. A known ID whose conversation the store no longer has
    /// selects no messages, which is the lookup's "no such conversation".
    /// Filtering messages on `conversation.id` instead joins every message to
    /// its conversation, and without statistics SQLite reads the whole
    /// message table for a page and again for its count
    /// (`docs/scalability-review.md`, `chat-transcript-uuid-join-offset-paging`).
    ///
    /// A conversation that is not saved yet has a temporary objectID, which
    /// names no row; it keeps the UUID form, which also matches its unsaved
    /// messages. (Core Data did answer the object form for a temporary ID on
    /// the context that holds it when this was written, but nothing says it
    /// must, and a background context cannot resolve one at all.)
    nonisolated static func transcriptPredicate(
        conversationUUID: UUID,
        knownConversationObjectID: NSManagedObjectID? = nil,
        includesPendingChanges: Bool,
        in context: NSManagedObjectContext
    ) throws -> (predicate: NSPredicate, conversationObjectID: NSManagedObjectID?)? {
        if let knownConversationObjectID, !knownConversationObjectID.isTemporaryID {
            return (
                MessagePredicates.visibleInChat(conversationObjectID: knownConversationObjectID),
                knownConversationObjectID
            )
        }

        let request = NSFetchRequest<NSManagedObjectID>(entityName: "Conversation")
        request.predicate = ConversationPredicates.id(conversationUUID)
        request.resultType = .managedObjectIDResultType
        request.fetchLimit = 1
        request.includesPendingChanges = includesPendingChanges

        guard let conversationObjectID = try context.fetch(request).first else { return nil }
        guard !conversationObjectID.isTemporaryID else {
            return (MessagePredicates.visibleInChat(conversationId: conversationUUID), nil)
        }
        return (MessagePredicates.visibleInChat(conversationObjectID: conversationObjectID), conversationObjectID)
    }

    nonisolated private static var messageSortDescriptors: [NSSortDescriptor] {
        [
            NSSortDescriptor(key: "internalDate", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
    }
}
