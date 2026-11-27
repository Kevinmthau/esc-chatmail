import CoreData
import Foundation

/// A private-queue context whose first fetch of one entity stops at a gate: it reports
/// that it was reached and waits on the context's queue until the test releases it.
/// For a load that must be suspended in Core Data when something else happens (an
/// invalidation that lands between the read and the cache write). Built like
/// `EntityFetchFailingContext`; later fetches of the entity pass once released.
final class FetchGatingContext: NSManagedObjectContext, @unchecked Sendable {
    private let lock = NSLock()
    private let gatedEntityName: String
    private var fetchReached = false
    private var isReleased = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private let releaseGate = DispatchSemaphore(value: 0)

    init(gatedEntityName: String, coordinator: NSPersistentStoreCoordinator) {
        self.gatedEntityName = gatedEntityName
        super.init(concurrencyType: .privateQueueConcurrencyType)
        persistentStoreCoordinator = coordinator
        mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    required init?(coder: NSCoder) {
        fatalError("not supported in tests")
    }

    /// Suspends until a gated fetch has started on the context's queue, which is after
    /// the caller of `context.perform` has suspended.
    func waitUntilFetchIsReached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fetchReached {
                lock.unlock()
                continuation.resume()
                return
            }
            reachedWaiters.append(continuation)
            lock.unlock()
        }
    }

    /// Lets the gated fetch, and every later one, go on.
    func releaseFetch() {
        lock.lock()
        isReleased = true
        lock.unlock()
        releaseGate.signal()
    }

    /// `executeFetchRequest:error:` is `NS_REFINED_FOR_SWIFT`; the generic
    /// `fetch(_:)` overlay calls through to this underscored `__execute(_:)`.
    override func __execute(_ request: NSFetchRequest<NSFetchRequestResult>) throws -> [Any] {
        guard request.entityName == gatedEntityName else {
            return try super.__execute(request)
        }
        lock.lock()
        let waiters = reachedWaiters
        reachedWaiters.removeAll()
        fetchReached = true
        let mustWait = !isReleased
        lock.unlock()
        waiters.forEach { $0.resume() }
        if mustWait {
            // Blocks the context's private queue, never an actor: the caller of
            // `context.perform` is suspended until this returns.
            releaseGate.wait()
            releaseGate.signal()
        }
        return try super.__execute(request)
    }
}
