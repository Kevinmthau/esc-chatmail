import Foundation
import CoreData

/// Handles data cleanup operations like duplicate removal and empty conversation cleanup.
///
/// The service is split across multiple files for organization:
/// - `DataCleanupService.swift` - Core structure and orchestration
/// - `DataCleanupService+Migration.swift` - Archive model migration
/// - `DataCleanupService+DuplicateRemoval.swift` - Duplicate message/conversation removal
/// - `DataCleanupService+EntityCleanup.swift` - Empty entity and draft cleanup
struct DataCleanupService: Sendable {

    // MARK: - Properties

    let coreDataStack: CoreDataStack
    let conversationManager: ConversationManager

    // MARK: - Initialization

    init(
        coreDataStack: CoreDataStack = .shared,
        conversationManager: ConversationManager = ConversationManager()
    ) {
        self.coreDataStack = coreDataStack
        self.conversationManager = conversationManager
    }

    // MARK: - Orchestration

    /// Runs full cleanup including duplicate removal.
    /// - Parameter context: The Core Data context
    func runFullCleanup(in context: NSManagedObjectContext) async {
        await migrateConversationsToArchiveModel(in: context)
        await removeDuplicateMessages(in: context)
        await removeDuplicateConversations(in: context)
        await mergeActiveConversationDuplicates(in: context)
    }

    /// Runs incremental cleanup (no duplicate message check).
    /// - Parameter context: The Core Data context
    func runIncrementalCleanup(in context: NSManagedObjectContext) async {
        await removeDuplicateConversations(in: context)
        await mergeActiveConversationDuplicates(in: context)
        await fixAndMergeIncorrectParticipantHashes(in: context)
        await removeEmptyConversations(in: context)
        await removeDraftMessages(in: context)
    }
}
