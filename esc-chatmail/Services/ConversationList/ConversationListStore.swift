import Foundation
import CoreData

struct ConversationListItem: Identifiable, Equatable {
    let id: NSManagedObjectID
    let snapshot: ConversationSnapshot

    init(conversation: Conversation) {
        self.id = conversation.objectID
        self.snapshot = ConversationSnapshot(from: conversation)
    }

    fileprivate var sortKey: SortKey {
        SortKey(pinned: snapshot.pinned, lastMessageDate: snapshot.lastMessageDate)
    }

    fileprivate struct SortKey: Equatable {
        let pinned: Bool
        let lastMessageDate: Date?
    }
}

struct ConversationListStore {
    private(set) var conversationsByID: [NSManagedObjectID: Conversation] = [:]
    private(set) var itemsByID: [NSManagedObjectID: ConversationListItem] = [:]
    private(set) var orderedIDs: [NSManagedObjectID] = []
    private(set) var visibleIDs: [NSManagedObjectID] = []
    private(set) var visibleItems: [ConversationListItem] = []

    var isEmpty: Bool {
        orderedIDs.isEmpty && itemsByID.isEmpty
    }

    func conversation(for objectID: NSManagedObjectID) -> Conversation? {
        conversationsByID[objectID]
    }

    mutating func replaceAll(
        with conversations: [Conversation],
        matchesVisibility: (Conversation) -> Bool
    ) {
        conversationsByID.removeAll(keepingCapacity: true)
        itemsByID.removeAll(keepingCapacity: true)
        orderedIDs.removeAll(keepingCapacity: true)
        visibleIDs.removeAll(keepingCapacity: true)
        visibleItems.removeAll(keepingCapacity: true)

        for conversation in conversations {
            let item = ConversationListItem(conversation: conversation)
            conversationsByID[item.id] = conversation
            itemsByID[item.id] = item
            orderedIDs.append(item.id)

            if matchesVisibility(conversation) {
                visibleIDs.append(item.id)
                visibleItems.append(item)
            }
        }
    }

    mutating func recomputeVisibleItems(matchesVisibility: (Conversation) -> Bool) {
        visibleIDs.removeAll(keepingCapacity: true)
        visibleItems.removeAll(keepingCapacity: true)

        for objectID in orderedIDs {
            guard let conversation = conversationsByID[objectID], matchesVisibility(conversation),
                  let item = itemsByID[objectID] else {
                continue
            }

            visibleIDs.append(objectID)
            visibleItems.append(item)
        }
    }

    mutating func applyChanges(
        updatedConversations: [Conversation],
        deletedIDs: Set<NSManagedObjectID>,
        isSourceConversation: (Conversation) -> Bool,
        matchesVisibility: (Conversation) -> Bool
    ) -> Set<NSManagedObjectID> {
        var removedIDs = Set<NSManagedObjectID>()

        for objectID in deletedIDs {
            if removeConversation(withID: objectID) {
                removedIDs.insert(objectID)
            }
        }

        for conversation in updatedConversations {
            let objectID = conversation.objectID

            guard isSourceConversation(conversation) else {
                if removeConversation(withID: objectID) {
                    removedIDs.insert(objectID)
                }
                continue
            }

            upsertConversation(conversation, matchesVisibility: matchesVisibility)
        }

        return removedIDs
    }

    mutating func removeAll() {
        conversationsByID.removeAll(keepingCapacity: true)
        itemsByID.removeAll(keepingCapacity: true)
        orderedIDs.removeAll(keepingCapacity: true)
        visibleIDs.removeAll(keepingCapacity: true)
        visibleItems.removeAll(keepingCapacity: true)
    }

    private mutating func upsertConversation(
        _ conversation: Conversation,
        matchesVisibility: (Conversation) -> Bool
    ) {
        let objectID = conversation.objectID
        let oldItem = itemsByID[objectID]
        let newItem = ConversationListItem(conversation: conversation)

        conversationsByID[objectID] = conversation
        itemsByID[objectID] = newItem

        let needsReorder = oldItem == nil || oldItem?.sortKey != newItem.sortKey
        if needsReorder {
            moveOrderedConversation(objectID, item: newItem)
        } else if !orderedIDs.contains(objectID) {
            orderedIDs.append(objectID)
        }

        let shouldBeVisible = matchesVisibility(conversation)
        let currentVisibleIndex = visibleIDs.firstIndex(of: objectID)

        switch (currentVisibleIndex, shouldBeVisible) {
        case (.none, false):
            return

        case (.none, true):
            let insertionIndex = visibleInsertionIndex(for: objectID)
            visibleIDs.insert(objectID, at: insertionIndex)
            visibleItems.insert(newItem, at: insertionIndex)

        case let (.some(index), false):
            visibleIDs.remove(at: index)
            visibleItems.remove(at: index)

        case let (.some(index), true):
            if needsReorder {
                visibleIDs.remove(at: index)
                visibleItems.remove(at: index)

                let insertionIndex = visibleInsertionIndex(for: objectID)
                visibleIDs.insert(objectID, at: insertionIndex)
                visibleItems.insert(newItem, at: insertionIndex)
            } else {
                visibleItems[index] = newItem
            }
        }
    }

    @discardableResult
    private mutating func removeConversation(withID objectID: NSManagedObjectID) -> Bool {
        let existed = conversationsByID.removeValue(forKey: objectID) != nil
        itemsByID.removeValue(forKey: objectID)

        if let index = orderedIDs.firstIndex(of: objectID) {
            orderedIDs.remove(at: index)
        }

        if let index = visibleIDs.firstIndex(of: objectID) {
            visibleIDs.remove(at: index)
            visibleItems.remove(at: index)
        }

        return existed
    }

    private mutating func moveOrderedConversation(_ objectID: NSManagedObjectID, item: ConversationListItem) {
        if let index = orderedIDs.firstIndex(of: objectID) {
            orderedIDs.remove(at: index)
        }

        let insertionIndex = orderedIDs.firstIndex { existingID in
            guard let existingItem = itemsByID[existingID] else { return false }
            return sortsBefore(item, existingItem)
        } ?? orderedIDs.endIndex

        orderedIDs.insert(objectID, at: insertionIndex)
    }

    private func visibleInsertionIndex(for objectID: NSManagedObjectID) -> Int {
        guard let orderedIndex = orderedIDs.firstIndex(of: objectID) else {
            return visibleIDs.count
        }

        let visibleSet = Set(visibleIDs)
        var count = 0

        for id in orderedIDs[..<orderedIndex] where visibleSet.contains(id) {
            count += 1
        }

        return count
    }

    private func sortsBefore(_ lhs: ConversationListItem, _ rhs: ConversationListItem) -> Bool {
        if lhs.snapshot.pinned != rhs.snapshot.pinned {
            return lhs.snapshot.pinned && !rhs.snapshot.pinned
        }

        let lhsDate = lhs.snapshot.lastMessageDate ?? .distantPast
        let rhsDate = rhs.snapshot.lastMessageDate ?? .distantPast

        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        return false
    }
}
