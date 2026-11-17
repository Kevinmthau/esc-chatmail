import Foundation
import CoreData

/// A store-backed private-queue context that counts the fetches it has run,
/// by entity. Every fetch, count and save still goes to the real store.
///
/// A fetch is counted once it has returned, so a test that waits for a count
/// knows the fetch is over. `count(for:)` is not a fetch and is not counted.
///
/// `@unchecked Sendable`: like `EntityFetchFailingContext`, the only mutable
/// state is `_fetchCounts`, guarded by `lock`; Core Data's own state stays on
/// the context's private queue.
final class FetchCountingContext: NSManagedObjectContext, @unchecked Sendable {
    private let lock = NSLock()
    private var _fetchCounts: [String: Int] = [:]

    init(coordinator: NSPersistentStoreCoordinator) {
        super.init(concurrencyType: .privateQueueConcurrencyType)
        persistentStoreCoordinator = coordinator
        mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    required init?(coder: NSCoder) {
        fatalError("not supported in tests")
    }

    /// How many fetches of `entityName` have returned.
    func fetchCount(ofEntity entityName: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return _fetchCounts[entityName, default: 0]
    }

    /// `executeFetchRequest:error:` is `NS_REFINED_FOR_SWIFT`; the generic
    /// `fetch(_:)` overlay calls through to this underscored `__execute(_:)`.
    override func __execute(_ request: NSFetchRequest<NSFetchRequestResult>) throws -> [Any] {
        let result = try super.__execute(request)
        if let entityName = request.entityName {
            lock.lock()
            _fetchCounts[entityName, default: 0] += 1
            lock.unlock()
        }
        return result
    }
}
