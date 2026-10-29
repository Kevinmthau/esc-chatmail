import Foundation
import CoreData

/// A store-backed context whose fetches of one entity throw a scripted error
/// while every other fetch, count and save goes to the real store. Lets a
/// test fail one specific read (e.g. the failure ledger) inside a full
/// orchestrator run without failing the reads that come before it.
///
/// `@unchecked Sendable`: like `ScriptedSaveContext`, the only mutable state
/// is `_failedFetches`, guarded by `lock`; Core Data's own state stays on the
/// context's private queue.
final class EntityFetchFailingContext: NSManagedObjectContext, @unchecked Sendable {
    private let lock = NSLock()
    private var _failedFetches = 0
    private let failingEntityName: String

    init(failingEntityName: String, coordinator: NSPersistentStoreCoordinator) {
        self.failingEntityName = failingEntityName
        super.init(concurrencyType: .privateQueueConcurrencyType)
        persistentStoreCoordinator = coordinator
        mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    required init?(coder: NSCoder) {
        fatalError("not supported in tests")
    }

    /// How many fetches of the failing entity were rejected.
    var failedFetches: Int {
        lock.lock()
        defer { lock.unlock() }
        return _failedFetches
    }

    /// `executeFetchRequest:error:` is `NS_REFINED_FOR_SWIFT`; the generic
    /// `fetch(_:)` overlay calls through to this underscored `__execute(_:)`.
    override func __execute(_ request: NSFetchRequest<NSFetchRequestResult>) throws -> [Any] {
        guard request.entityName == failingEntityName else {
            return try super.__execute(request)
        }
        lock.lock()
        _failedFetches += 1
        lock.unlock()
        throw NSError(
            domain: "EntityFetchFailingContext",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "scripted \(failingEntityName) fetch failure"]
        )
    }
}
