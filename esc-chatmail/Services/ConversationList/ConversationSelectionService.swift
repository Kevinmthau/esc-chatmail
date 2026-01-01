import Foundation
import CoreData
import Combine

/// Service for handling multi-select operations in the conversation list
@MainActor
final class ConversationSelectionService: ObservableObject {
    // MARK: - Published State

    @Published var isSelecting = false
    @Published var selectedConversationIDs: Set<NSManagedObjectID> = []

    // MARK: - Dependencies

    private let messageActions: MessageActions
    private let coreDataStack: CoreDataStack

    // MARK: - Initialization

    init(messageActions: MessageActions, coreDataStack: CoreDataStack) {
        self.messageActions = messageActions
        self.coreDataStack = coreDataStack
    }

    // MARK: - Selection Operations

    /// Toggles selection state for a conversation
    func toggleSelection(for conversation: Conversation) {
        if selectedConversationIDs.contains(conversation.objectID) {
            selectedConversationIDs.remove(conversation.objectID)
        } else {
            selectedConversationIDs.insert(conversation.objectID)
        }
    }

    /// Selects or deselects all conversations in the list
    func selectAll(from conversations: [Conversation]) {
        if selectedConversationIDs.count == conversations.count {
            selectedConversationIDs.removeAll()
        } else {
            selectedConversationIDs = Set(conversations.map { $0.objectID })
        }
    }

    /// Cancels selection mode and clears all selections
    func cancelSelection() {
        isSelecting = false
        selectedConversationIDs.removeAll()
    }

    /// Toggles selection mode on/off
    func toggleSelectionMode() {
        isSelecting.toggle()
        if !isSelecting {
            selectedConversationIDs.removeAll()
        }
    }

    /// Returns the number of selected conversations
    var selectedCount: Int {
        selectedConversationIDs.count
    }

    /// Checks if a conversation is selected
    func isSelected(_ conversation: Conversation) -> Bool {
        selectedConversationIDs.contains(conversation.objectID)
    }

    // MARK: - Batch Operations

    /// Archives all selected conversations
    func archiveSelectedConversations() {
        let context = coreDataStack.viewContext
        let conversationsToArchive = selectedConversationIDs.compactMap { objectID in
            try? context.existingObject(with: objectID) as? Conversation
        }

        let count = conversationsToArchive.count
        Log.debug("Starting batch archive of \(count) conversations from \(selectedConversationIDs.count) selected IDs", category: .message)
        for (index, conv) in conversationsToArchive.enumerated() {
            let messageCount = conv.messages?.count ?? 0
            Log.debug("[\(index + 1)/\(count)] '\(conv.displayName ?? "unknown")' (id: \(conv.id), messages: \(messageCount))", category: .message)
        }

        selectedConversationIDs.removeAll()
        isSelecting = false

        Task {
            for (index, conversation) in conversationsToArchive.enumerated() {
                Log.debug("[\(index + 1)/\(count)] Processing '\(conversation.displayName ?? "unknown")'...", category: .message)
                await messageActions.archiveConversation(conversation: conversation)
                Log.debug("[\(index + 1)/\(count)] Archived '\(conversation.displayName ?? "unknown")'", category: .message)
            }
            Log.info("Batch archive complete - \(count) conversations archived", category: .message)
        }
    }
}
