import Foundation
import CoreData

extension CoreDataStack {
    /// Convenience method for saves that logs errors but doesn't throw
    /// Uses async perform to avoid blocking the main thread
    /// - Parameters:
    ///   - context: The managed object context to save
    ///   - caller: Optional identifier for debugging which code path called this
    /// - Returns: true if save succeeded or no changes were needed, false if save failed
    @discardableResult
    func saveIfNeeded(context: NSManagedObjectContext, caller: String = #function) -> Bool {
        guard context.hasChanges else { return true }

        var saveSucceeded = false

        context.performAndWait {
            guard context.hasChanges else {
                saveSucceeded = true
                return
            }
            do {
                try context.save()
                saveSucceeded = true
            } catch let error as NSError {
                Log.error("Core Data save error in \(caller): \(error.localizedDescription)", category: .coreData)

                // Log additional details for debugging
                if let detailedErrors = error.userInfo[NSDetailedErrorsKey] as? [NSError] {
                    for detailedError in detailedErrors {
                        Log.debug("  - Detail: \(detailedError.localizedDescription)", category: .coreData)
                        if let validationObject = detailedError.userInfo[NSValidationObjectErrorKey] as? NSManagedObject {
                            Log.debug("    Object: \(validationObject.entity.name ?? "unknown")", category: .coreData)
                        }
                    }
                }

                // Attempt recovery for merge conflicts
                if error.code == NSManagedObjectMergeError || error.code == NSPersistentStoreSaveConflictsError {
                    context.rollback()
                    Log.warning("Rolled back context due to merge conflict", category: .coreData)
                }

                saveSucceeded = false
            }
        }

        return saveSucceeded
    }

    /// Async version of saveIfNeeded that returns success status via completion
    func saveIfNeededAsync(context: NSManagedObjectContext, caller: String = #function, completion: ((Bool) -> Void)? = nil) {
        guard context.hasChanges else {
            completion?(true)
            return
        }

        context.perform {
            guard context.hasChanges else {
                completion?(true)
                return
            }
            do {
                try context.save()
                completion?(true)
            } catch let error as NSError {
                Log.error("Core Data save error in \(caller): \(error.localizedDescription)", category: .coreData)

                // Log additional details for debugging
                if let detailedErrors = error.userInfo[NSDetailedErrorsKey] as? [NSError] {
                    for detailedError in detailedErrors {
                        Log.debug("  - Detail: \(detailedError.localizedDescription)", category: .coreData)
                    }
                }

                completion?(false)
            }
        }
    }

    func saveAsync(context: NSManagedObjectContext) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.perform {
                guard context.hasChanges else {
                    continuation.resume(returning: ())
                    return
                }
                do {
                    try context.save()
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: CoreDataError.saveFailed(error))
                }
            }
        }
    }
}
