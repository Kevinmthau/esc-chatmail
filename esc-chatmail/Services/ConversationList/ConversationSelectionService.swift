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
    private let taskManager = ViewModelTaskManager()

    // MARK: - Initialization

    init(messageActions: MessageActions, coreDataStack: CoreDataStack) {
        self.messageActions = messageActions
        self.coreDataStack = coreDataStack
    }

    // MARK: - Selection Operations

    /// Toggles selection state for a conversation
    func toggleSelection(for conversation: Conversation) {
        toggleSelection(for: conversation.objectID)
    }

    /// Toggles selection state for a conversation by object identifier.
    func toggleSelection(for objectID: NSManagedObjectID) {
        if selectedConversationIDs.contains(objectID) {
            selectedConversationIDs.remove(objectID)
        } else {
            selectedConversationIDs.insert(objectID)
        }
    }

    /// Selects or deselects all conversations in the list
    func selectAll(from conversations: [Conversation]) {
        selectAll(conversationIDs: conversations.map(\.objectID))
    }

    /// Selects or deselects all conversations in the list by identifier.
    func selectAll(conversationIDs: [NSManagedObjectID]) {
        if selectedConversationIDs.count == conversationIDs.count {
            selectedConversationIDs.removeAll()
        } else {
            selectedConversationIDs = Set(conversationIDs)
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

    /// Checks if a conversation identifier is selected
    func isSelected(_ objectID: NSManagedObjectID) -> Bool {
        selectedConversationIDs.contains(objectID)
    }

    // MARK: - Batch Operations

    /// Archives all selected conversations in a single batch operation
    func archiveSelectedConversations() {
        let context = coreDataStack.viewContext
        let conversationsToArchive = selectedConversationIDs.compactMap { objectID in
            try? context.existingObject(with: objectID) as? Conversation
        }

        guard !conversationsToArchive.isEmpty else {
            Log.debug("No conversations to archive", category: .message)
            return
        }

        Log.info("Batch archive: \(conversationsToArchive.count) conversations", category: .message)

        // Clear selection immediately for instant UI feedback
        selectedConversationIDs.removeAll()
        isSelecting = false

        // Single batch operation instead of sequential loop
        taskManager.run("archive") { [messageActions] in
            await messageActions.archiveConversations(conversations: conversationsToArchive)
        }
    }

    /// Reports all selected conversations as spam in a single batch operation
    func reportSpamSelectedConversations() {
        let context = coreDataStack.viewContext
        let conversationsToReport = selectedConversationIDs.compactMap { objectID in
            try? context.existingObject(with: objectID) as? Conversation
        }

        guard !conversationsToReport.isEmpty else {
            Log.debug("No conversations to report as spam", category: .message)
            return
        }

        Log.info("Batch spam report: \(conversationsToReport.count) conversations", category: .message)

        // Clear selection immediately for instant UI feedback
        selectedConversationIDs.removeAll()
        isSelecting = false

        // Single batch operation instead of sequential loop
        taskManager.run("reportSpam") { [messageActions] in
            await messageActions.reportSpamConversations(conversations: conversationsToReport)
        }
    }

    /// Cancels any pending batch operations
    func cancelTasks() {
        taskManager.cancelAll()
    }
}
