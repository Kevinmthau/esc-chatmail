import Foundation
import CoreData

/// A store-backed context that keeps a copy of every fetch request of one entity it
/// executes, so a test can ask what the code under test asked the store for: which rows
/// a request named and which relationships it prefetched. Neither shows in the context
/// afterwards: a prefetch registers no destination object and leaves the relationship
/// reading as a fault (measured 2026-11-28, iOS 27.0 simulator).
///
/// `@unchecked Sendable`: like `EntityFetchFailingContext`, the recorded requests are
/// guarded by `lock`; Core Data's own state stays on the context's queue.
final class FetchRecordingContext: NSManagedObjectContext, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [NSFetchRequest<NSFetchRequestResult>] = []
    private let recordedEntityName: String

    /// `concurrencyType` is main-queue for code that touches its context directly from
    /// the main actor (`ConversationListViewModel` fetches on the context it observes).
    init(
        recordedEntityName: String,
        coordinator: NSPersistentStoreCoordinator,
        concurrencyType: NSManagedObjectContextConcurrencyType = .mainQueueConcurrencyType
    ) {
        self.recordedEntityName = recordedEntityName
        super.init(concurrencyType: concurrencyType)
        persistentStoreCoordinator = coordinator
        mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    required init?(coder: NSCoder) {
        fatalError("not supported in tests")
    }

    /// Copies of the executed requests of the recorded entity, oldest first.
    var executedRequests: [NSFetchRequest<NSFetchRequestResult>] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    /// The objectIDs named by the `self IN %@` predicates of the executed requests that
    /// prefetch `keyPath`. A request whose predicate is not of that form names none.
    func objectIDsNamed(byRequestsPrefetching keyPath: String) -> Set<NSManagedObjectID> {
        Set(executedRequests
            .filter { ($0.relationshipKeyPathsForPrefetching ?? []).contains(keyPath) }
            .flatMap { request -> [NSManagedObjectID] in
                guard let comparison = request.predicate as? NSComparisonPredicate,
                      comparison.predicateOperatorType == .in else {
                    return []
                }
                return comparison.rightExpression.constantValue as? [NSManagedObjectID] ?? []
            })
    }

    /// `executeFetchRequest:error:` is `NS_REFINED_FOR_SWIFT`; the generic
    /// `fetch(_:)` overlay calls through to this underscored `__execute(_:)`.
    override func __execute(_ request: NSFetchRequest<NSFetchRequestResult>) throws -> [Any] {
        if request.entityName == recordedEntityName,
           let copy = request.copy() as? NSFetchRequest<NSFetchRequestResult> {
            lock.lock()
            _requests.append(copy)
            lock.unlock()
        }
        return try super.__execute(request)
    }
}
