import Foundation
import CoreData

/// Deletes persistent history transactions older than a retention window.
///
/// The store runs with `NSPersistentHistoryTrackingKey` enabled but nothing
/// consumes history tokens, so history rows accumulate unbounded and bloat
/// the SQLite file. Purging is best-effort: failures are logged and reported,
/// never thrown, so callers can keep running their remaining maintenance.
enum PersistentHistoryPurger {

    static let defaultRetentionDays = 7

    /// Deletes history transactions recorded before the cutoff.
    /// Must be called on the context's queue (inside `perform`).
    ///
    /// - Returns: `true` if the delete request executed successfully.
    @discardableResult
    static func purgeHistory(olderThan cutoff: Date, in context: NSManagedObjectContext) -> Bool {
        let request = NSPersistentHistoryChangeRequest.deleteHistory(before: cutoff)
        do {
            try context.execute(request)
            Log.debug("Purged persistent history older than \(cutoff)", category: .coreData)
            return true
        } catch {
            Log.error("Persistent history purge failed", category: .coreData, error: error)
            return false
        }
    }

    /// Convenience: purges history older than `defaultRetentionDays`.
    @discardableResult
    static func purgeHistory(in context: NSManagedObjectContext) -> Bool {
        let cutoff = Date().addingTimeInterval(-TimeInterval(defaultRetentionDays) * 24 * 60 * 60)
        return purgeHistory(olderThan: cutoff, in: context)
    }
}
