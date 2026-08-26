import SwiftUI
import CoreData
import Combine

// MARK: - Row cache and page loading

extension VirtualScrollState {
    func setMessageWindow(_ window: MessageWindow) {
        messageWindow = window
        resolvedRowsByAbsoluteIndex.removeAll()

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
        request.predicate = MessagePredicates.visibleInChat(conversationId: conversationUUID)
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
        guard let conversationUUID = UUID(uuidString: conversationId) else {
            return VirtualScrollMessagePage(messageIDs: [], totalCount: 0)
        }

        let predicate = MessagePredicates.visibleInChat(conversationId: conversationUUID)
        nonisolated(unsafe) let safePredicate = predicate

        return await context.perform {
            do {
                let messageIDs: [NSManagedObjectID]
                if range.isEmpty {
                    messageIDs = []
                } else {
                    let request = NSFetchRequest<NSManagedObjectID>(entityName: "Message")
                    request.predicate = safePredicate
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
                countRequest.predicate = safePredicate
                countRequest.includesPendingChanges = false
                let totalCount = try context.count(for: countRequest)

                return VirtualScrollMessagePage(
                    messageIDs: messageIDs,
                    totalCount: totalCount
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
        in context: NSManagedObjectContext
    ) async -> VirtualScrollMessagePage {
        guard let conversationUUID = UUID(uuidString: conversationId) else {
            return VirtualScrollMessagePage(messageIDs: [], totalCount: 0)
        }

        let predicate = MessagePredicates.visibleInChat(conversationId: conversationUUID)
        nonisolated(unsafe) let safePredicate = predicate

        return await context.perform {
            do {
                let messages: [Message]
                if range.isEmpty {
                    messages = []
                } else {
                    let request = NSFetchRequest<Message>(entityName: "Message")
                    request.predicate = safePredicate
                    request.sortDescriptors = messageSortDescriptors
                    request.fetchOffset = range.lowerBound
                    request.fetchLimit = range.count
                    request.fetchBatchSize = 20
                    request.includesPendingChanges = true
                    messages = try context.fetch(request)
                }

                let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
                countRequest.predicate = safePredicate
                countRequest.includesPendingChanges = true
                let totalCount = try context.count(for: countRequest)

                return VirtualScrollMessagePage(
                    messageIDs: messages.map(\.objectID),
                    totalCount: totalCount
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

    nonisolated private static var messageSortDescriptors: [NSSortDescriptor] {
        [
            NSSortDescriptor(key: "internalDate", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
    }
}
