import CoreData
import Foundation

extension CoreDataStack {
    /// Throws `CoreDataError.storeNotAttached` unless `context`'s coordinator has a store
    /// attached. Call it inside the context's `perform`, before any read whose empty answer
    /// allows something to be deleted.
    ///
    /// A coordinator with no store answers a fetch with `[]` and no error (the note on the
    /// tests' `FailingReadStore`; `AttachedStoreGuardTests` shows it), and a context can be
    /// handed out with none: a load that failed and was kept (`.keepStore`) attaches
    /// nothing, a timeout retry leaves the coordinator empty until it runs, and
    /// `newBackgroundContext()` checks neither. So a
    /// read there would say that no message and no attachment exists, and the orphan sweeps
    /// and the deleted-row removers would take that as leave to remove every body and every
    /// attachment, the user's own `local_` originals among them. Neither `isStoreLoaded`
    /// nor the bootstrap's readiness proves the store is there: a stack built for tests sets
    /// the flag with no load, and the bootstrap stays ready after a reset's reload fails.
    /// The context's own coordinator is the witness.
    static func requireAttachedStore(in context: NSManagedObjectContext) throws {
        guard hasAttachedStore(context) else {
            throw CoreDataError.storeNotAttached
        }
    }

    /// Whether `context`'s coordinator has a store attached. Read it inside the context's
    /// `perform`.
    static func hasAttachedStore(_ context: NSManagedObjectContext) -> Bool {
        guard let coordinator = context.persistentStoreCoordinator else { return false }
        return !coordinator.persistentStores.isEmpty
    }
}
