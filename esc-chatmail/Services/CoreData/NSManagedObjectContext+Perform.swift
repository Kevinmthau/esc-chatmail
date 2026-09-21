import Foundation
import CoreData

/// Save helpers for context-queued and synchronous Core Data callers.
extension NSManagedObjectContext {
    /// Saves the context if it has changes, logging errors
    /// - Parameter caller: Description of the calling context for logging
    /// - Returns: true if save succeeded or no changes, false on error
    @discardableResult
    func performSaveIfNeeded(caller: String = #function) async -> Bool {
        await perform {
            guard self.hasChanges else { return true }
            do {
                try self.save()
                return true
            } catch {
                Log.error("Core Data save failed in \(caller)", category: .coreData, error: error)
                return false
            }
        }
    }

    /// Synchronous save with logging - use inside context.perform {} blocks
    /// Replaces `try? context.save()` with proper error logging
    /// - Parameters:
    ///   - operation: Description of what operation triggered the save (e.g., "update profile photo")
    ///   - category: Log category, defaults to .coreData
    /// - Returns: true if save succeeded or no changes, false on error
    @discardableResult
    func saveOrLog(operation: String, category: LogCategory = .coreData) -> Bool {
        guard hasChanges else { return true }
        do {
            try save()
            return true
        } catch {
            Log.error("Failed to save: \(operation)", category: category, error: error)
            return false
        }
    }
}
