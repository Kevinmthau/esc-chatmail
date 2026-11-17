import Foundation
import CoreData

/// Hands out `FetchCountingContext`s over one coordinator and adds up what
/// they counted, for code that makes a background context of its own for
/// each piece of work.
///
/// `@unchecked Sendable`: `contexts` is guarded by `lock`.
final class FetchCountingContextFactory: @unchecked Sendable {
    private let coordinator: NSPersistentStoreCoordinator
    private let lock = NSLock()
    private var contexts: [FetchCountingContext] = []

    init(coordinator: NSPersistentStoreCoordinator) {
        self.coordinator = coordinator
    }

    func makeContext() -> FetchCountingContext {
        let context = FetchCountingContext(coordinator: coordinator)
        lock.lock()
        contexts.append(context)
        lock.unlock()
        return context
    }

    /// How many fetches of `entityName` have returned, over every context
    /// handed out so far.
    func fetchCount(ofEntity entityName: String) -> Int {
        lock.lock()
        let made = contexts
        lock.unlock()
        return made.reduce(0) { $0 + $1.fetchCount(ofEntity: entityName) }
    }
}
