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

    enum IncrementalCleanupSchedule {
        static let lastRunTimeKey = "dataCleanupService.lastIncrementalCleanupAt"
        static let interval: TimeInterval = 6 * 60 * 60

        static func isDue(
            now: Date = Date(),
            defaults: UserDefaults = .standard
        ) -> Bool {
            let lastRun = defaults.double(forKey: lastRunTimeKey)
            guard lastRun > 0 else { return true }
            return now.timeIntervalSince1970 - lastRun >= interval
        }

        static func markRun(
            now: Date = Date(),
            defaults: UserDefaults = .standard
        ) {
            defaults.set(now.timeIntervalSince1970, forKey: lastRunTimeKey)
        }
    }

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
        await mergeConversationsSplitByGmThreadIdIfNeeded(in: context)

        guard IncrementalCleanupSchedule.isDue() else {
            Log.debug("Skipping incremental cleanup; cadence not due", category: .coreData)
            return
        }

        await runMaintenanceCleanup(in: context)
        IncrementalCleanupSchedule.markRun()
    }

    /// Runs incremental cleanup in a dedicated background context.
    /// This avoids resetting or batch-deleting the active sync transaction context.
    func runIncrementalCleanup() async {
        let context = coreDataStack.newBackgroundContext()
        await runIncrementalCleanup(in: context)
        _ = await context.performSaveIfNeeded(caller: "DataCleanupService.runIncrementalCleanup")
    }

    /// Runs the heavier store-wide maintenance tasks.
    /// Use this for periodic maintenance or one-shot repair passes, not every sync.
    func runMaintenanceCleanup(in context: NSManagedObjectContext) async {
        await removeDuplicateMessages(in: context)
        await removeDuplicateConversations(in: context)
        await mergeActiveConversationDuplicates(in: context)
        await fixAndMergeIncorrectParticipantHashes(in: context)
        await mergeConversationsSplitByGmThreadIdIfNeeded(in: context)
        await removeEmptyConversations(in: context)
        await removeDraftMessages(in: context)
        await cleanupOrphanedData(in: context)
    }
}
