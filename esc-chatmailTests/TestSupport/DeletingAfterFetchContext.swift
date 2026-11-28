import Foundation
import CoreData

/// A store-backed context that, once, deletes a row from the store through another
/// context right after a fetch of one entity has returned: the race in which a sibling
/// context's delete lands between a batched fetch's ID query and the faulting of its rows.
/// The deleted row's object in the returned array is then a tombstone when it fires, which
/// reads nil for every attribute (`shouldDeleteInaccessibleFaults`). Measured 2026-11-28
/// on a SQLite store with `ConversationWindowProvider.fetchWindow`: the window came back
/// without the row.
///
/// `@unchecked Sendable`: `pendingDeletion` is guarded by `lock`; Core Data's own state
/// stays on the context's queue, and the deletion runs on the deleting context's queue
/// through `performAndWait`.
final class DeletingAfterFetchContext: NSManagedObjectContext, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingDeletion: (objectID: NSManagedObjectID, through: NSManagedObjectContext)?
    private let entityName: String

    /// `concurrencyType` is main-queue for code that touches its context directly from
    /// the main actor (`ConversationListViewModel` fetches on the context it observes).
    init(
        entityName: String,
        coordinator: NSPersistentStoreCoordinator,
        concurrencyType: NSManagedObjectContextConcurrencyType = .mainQueueConcurrencyType
    ) {
        self.entityName = entityName
        super.init(concurrencyType: concurrencyType)
        persistentStoreCoordinator = coordinator
        mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    required init?(coder: NSCoder) {
        fatalError("not supported in tests")
    }

    /// Arms one deletion of `objectID`, saved through `context` (another context on the
    /// same store), after the next fetch of the entity returns.
    func deleteAfterNextFetch(_ objectID: NSManagedObjectID, through context: NSManagedObjectContext) {
        lock.lock()
        pendingDeletion = (objectID, context)
        lock.unlock()
    }

    /// `executeFetchRequest:error:` is `NS_REFINED_FOR_SWIFT`; the generic
    /// `fetch(_:)` overlay calls through to this underscored `__execute(_:)`.
    override func __execute(_ request: NSFetchRequest<NSFetchRequestResult>) throws -> [Any] {
        let result = try super.__execute(request)
        guard request.entityName == entityName else { return result }
        lock.lock()
        let deletion = pendingDeletion
        pendingDeletion = nil
        lock.unlock()
        if let deletion {
            try deletion.through.performAndWait {
                deletion.through.delete(try deletion.through.existingObject(with: deletion.objectID))
                try deletion.through.save()
            }
        }
        return result
    }
}
