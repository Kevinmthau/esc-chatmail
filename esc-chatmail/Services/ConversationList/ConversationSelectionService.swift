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
    private let viewContext: NSManagedObjectContext
    private let taskManager = ViewModelTaskManager()

    // MARK: - Initialization

    /// - Parameters:
    ///   - messageActions: Executor for the batch archive / spam operations.
    ///   - viewContext: Context the batch actions resolve the selected object
    ///     identifiers on — the only piece of the Core Data stack this
    ///     service uses.
    init(messageActions: MessageActions, viewContext: NSManagedObjectContext) {
        self.messageActions = messageActions
        self.viewContext = viewContext
    }

    // MARK: - Selection Operations

    /// Toggles selection state for a conversation by object identifier.
    func toggleSelection(for objectID: NSManagedObjectID) {
        if selectedConversationIDs.contains(objectID) {
            selectedConversationIDs.remove(objectID)
        } else {
            selectedConversationIDs.insert(objectID)
        }
    }

    /// Selects or deselects all conversations in the list by identifier.
    ///
    /// Toggles on set equality — the honest form of the toggle. It relies on
    /// `retainSelection(within:)`'s invariant that the selection is always a
    /// subset of the visible rows, so "selection equals the visible set" is
    /// exactly "everything visible is already selected". Count equality would
    /// also treat a stale selection of the same size as fully selected and
    /// clear it instead of selecting the visible rows.
    func selectAll(conversationIDs: [NSManagedObjectID]) {
        if selectedConversationIDs == Set(conversationIDs) {
            selectedConversationIDs.removeAll()
        } else {
            selectedConversationIDs = Set(conversationIDs)
        }
    }

    /// Drops every selected identifier that is not among `visibleIDs`.
    ///
    /// Invariant: the selection is always a subset of the rows the list
    /// currently shows. The "N Selected" title, the Select All / Deselect All
    /// label (the view compares `selectedConversationIDs.count` against the
    /// visible `filteredConversationItems.count`) and the batch archive / spam
    /// actions all assume it, so a row that leaves the window for any reason
    /// (filter or search mismatch, trim, archive, delete, invalidate-all)
    /// must leave the selection with it. The `isSubset` guard keeps the
    /// `@Published` set untouched on the common publish where nothing left,
    /// so observers are not re-notified on every list publish.
    func retainSelection(within visibleIDs: Set<NSManagedObjectID>) {
        guard !selectedConversationIDs.isSubset(of: visibleIDs) else { return }
        selectedConversationIDs.formIntersection(visibleIDs)
    }

    /// Toggles selection mode on/off
    func toggleSelectionMode() {
        isSelecting.toggle()
        if !isSelecting {
            selectedConversationIDs.removeAll()
        }
    }

    // MARK: - Batch Operations

    /// Archives all selected conversations in a single batch operation
    func archiveSelectedConversations() {
        performBatchAction(
            taskKey: "archive",
            emptyLogMessage: "No conversations to archive",
            batchLogPrefix: "Batch archive"
        ) { [messageActions] conversations in
            await messageActions.archiveConversations(conversations: conversations)
        }
    }

    /// Reports all selected conversations as spam in a single batch operation
    func reportSpamSelectedConversations() {
        performBatchAction(
            taskKey: "reportSpam",
            emptyLogMessage: "No conversations to report as spam",
            batchLogPrefix: "Batch spam report"
        ) { [messageActions] conversations in
            await messageActions.reportSpamConversations(conversations: conversations)
        }
    }

    /// Shared template for the batch actions: resolves the selected
    /// identifiers on the view context, clears the selection, then dispatches
    /// one batch `MessageActions` call. Resolution must precede the clear —
    /// the dispatched operation acts on the conversations that were selected
    /// at call time, not on the (already cleared) live set.
    ///
    /// - Parameters:
    ///   - taskKey: `ViewModelTaskManager` key; a repeat invocation cancels
    ///     the previous task of the same kind.
    ///   - emptyLogMessage: Debug log emitted when nothing is selected.
    ///   - batchLogPrefix: Prefix of the info log announcing the batch size.
    ///   - action: The batch `MessageActions` call, given the resolved
    ///     conversations.
    private func performBatchAction(
        taskKey: String,
        emptyLogMessage: String,
        batchLogPrefix: String,
        _ action: @escaping ([Conversation]) async -> Void
    ) {
        let conversations = selectedConversationIDs.compactMap { objectID in
            try? viewContext.existingObject(with: objectID) as? Conversation
        }

        guard !conversations.isEmpty else {
            Log.debug(emptyLogMessage, category: .message)
            return
        }

        Log.info("\(batchLogPrefix): \(conversations.count) conversations", category: .message)

        // Clear selection immediately for instant UI feedback
        selectedConversationIDs.removeAll()
        isSelecting = false

        // Single batch operation instead of sequential loop
        taskManager.run(taskKey) {
            await action(conversations)
        }
    }

    /// Cancels any pending batch operations
    func cancelTasks() {
        taskManager.cancelAll()
    }
}
