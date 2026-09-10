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
    let conversationMutationSerializer: ConversationRollupMutationSerializer
    // Both conformers are thread-safe (UserDefaults; the locked test store), but
    // the protocol itself cannot require Sendable without breaking UserDefaults.
    nonisolated(unsafe) let migrationFlags: MigrationFlagStore
    /// Alias source for participant-identity recomputation. Must match what the
    /// sync router excludes (AliasManager), or repair passes rewrite hashes with
    /// a different self-exclusion set than routing uses and chats flip-flop.
    /// Injected so tests avoid the process-global AliasManager/Contacts path.
    let identityAliasProvider: @Sendable (NSManagedObjectContext) async -> Set<String>

    // MARK: - Initialization

    init(
        coreDataStack: CoreDataStack = .shared,
        conversationManager: ConversationManager = ConversationManager(),
        conversationMutationSerializer: ConversationRollupMutationSerializer = .shared,
        migrationFlags: MigrationFlagStore = UserDefaults.standard,
        identityAliasProvider: @escaping @Sendable (NSManagedObjectContext) async -> Set<String> = { context in
            await AliasManager.shared.getAliases(from: context)
        }
    ) {
        self.coreDataStack = coreDataStack
        self.conversationManager = conversationManager
        self.conversationMutationSerializer = conversationMutationSerializer
        self.migrationFlags = migrationFlags
        self.identityAliasProvider = identityAliasProvider
    }

    // MARK: - Orchestration

    /// Runs full cleanup including duplicate removal.
    /// - Parameter context: The Core Data context
    func runFullCleanup(in context: NSManagedObjectContext) async {
        await conversationMutationSerializer.performCleanupSensitiveMutation { [self] in
            await migrateConversationsToArchiveModel(in: context)
            await splitConversationsByParticipantSetIfNeeded(in: context)
            await decodeRFC2047HeaderTextIfNeeded(in: context)
            await removeDuplicateMessages(in: context)
            await removeDuplicateConversations(in: context)
            await mergeActiveConversationDuplicates(in: context)
            _ = await context.performSaveIfNeeded(
                caller: "DataCleanupService.runFullCleanup"
            )
        }
    }

    /// Runs incremental cleanup (no duplicate message check).
    /// - Parameter context: The Core Data context
    func runIncrementalCleanup(in context: NSManagedObjectContext) async {
        await conversationMutationSerializer.performCleanupSensitiveMutation { [self] in
            await splitConversationsByParticipantSetIfNeeded(in: context)
            await decodeRFC2047HeaderTextIfNeeded(in: context)

            if IncrementalCleanupSchedule.isDue() {
                await runMaintenanceCleanupWithoutSerialization(in: context)
                IncrementalCleanupSchedule.markRun()
            } else {
                Log.debug("Skipping incremental cleanup; cadence not due", category: .coreData)
            }

            _ = await context.performSaveIfNeeded(
                caller: "DataCleanupService.runIncrementalCleanup"
            )
        }
    }

    /// Runs incremental cleanup in a dedicated background context.
    /// This avoids resetting or batch-deleting the active sync transaction context.
    func runIncrementalCleanup() async {
        let context = coreDataStack.newBackgroundContext()
        await runIncrementalCleanup(in: context)
    }

    /// Runs the heavier store-wide maintenance tasks.
    /// Use this for periodic maintenance or one-shot repair passes, not every sync.
    func runMaintenanceCleanup(in context: NSManagedObjectContext) async {
        await conversationMutationSerializer.performCleanupSensitiveMutation { [self] in
            await runMaintenanceCleanupWithoutSerialization(in: context)
            _ = await context.performSaveIfNeeded(
                caller: "DataCleanupService.runMaintenanceCleanup"
            )
        }
    }

    private func runMaintenanceCleanupWithoutSerialization(
        in context: NSManagedObjectContext
    ) async {
        await removeDuplicateMessages(in: context)
        await removeDuplicateConversations(in: context)
        await mergeActiveConversationDuplicates(in: context)
        await fixAndMergeIncorrectParticipantHashes(in: context)
        await removeEmptyConversations(in: context)
        await removeDraftMessages(in: context)
        await cleanupOrphanedData(in: context)
        // Run last: the orphan sweeps above delete participation rows, and
        // merging is cheaper once those are gone.
        await mergeDuplicatePersons(in: context)
        await mergeDuplicateLabels(in: context)
    }

    /// Pending optimistic-send anchors are a destructive-cleanup exclusion.
    /// Callers deliberately fail closed if this fetch throws.
    func pendingSendConversationIDs(in context: NSManagedObjectContext) throws -> Set<UUID> {
        Set(try context.fetch(OutboundSendMutationRecord.fetchRequest()).compactMap(\.conversationId))
    }
}
