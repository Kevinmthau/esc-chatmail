import Foundation
import CoreData

extension CoreDataStack {

    /// Performs work in a new background context, automatically saving if changes exist.
    ///
    /// This combines context creation, work execution, and saving into a single call,
    /// reducing boilerplate for common Core Data background operations.
    ///
    /// Usage:
    /// ```swift
    /// let count = try await coreDataStack.performBackground { context in
    ///     let request = Message.fetchRequest()
    ///     return try context.count(for: request)
    /// }
    /// ```
    ///
    /// - Parameter block: The work to perform in the background context
    /// - Returns: The result of the work
    /// - Throws: Any error from the work or from saving
    func performBackground<T: Sendable>(
        _ block: @escaping (NSManagedObjectContext) throws -> T
    ) async throws -> T {
        try await waitForStoreToLoad()

        let context = newBackgroundContext()

        return try await context.perform {
            let result = try block(context)

            if context.hasChanges {
                try context.save()
            }

            return result
        }
    }

    /// Performs work in a new background context without throwing.
    ///
    /// Errors during save are logged but not propagated. Use this for
    /// non-critical operations where save failure shouldn't affect the caller.
    ///
    /// - Parameters:
    ///   - caller: Identifier for error logging
    ///   - block: The work to perform in the background context
    /// - Returns: The result of the work, or nil if an error occurred
    func performBackgroundSafe<T: Sendable>(
        caller: String = #function,
        _ block: @escaping (NSManagedObjectContext) throws -> T
    ) async -> T? {
        do {
            try await waitForStoreToLoad()
        } catch {
            Log.error("Store not loaded in \(caller)", category: .coreData, error: error)
            return nil
        }

        let context = newBackgroundContext()

        return await context.perform {
            do {
                let result = try block(context)

                if context.hasChanges {
                    try context.save()
                }

                return result
            } catch {
                Log.error("Background operation failed in \(caller)", category: .coreData, error: error)
                return nil
            }
        }
    }

    /// Performs a fetch operation in a background context.
    ///
    /// Convenience method for fetch-only operations that don't modify data.
    ///
    /// - Parameter block: The fetch operation to perform
    /// - Returns: The fetched results
    /// - Throws: Any error from the fetch
    func fetchInBackground<T: Sendable>(
        _ block: @escaping (NSManagedObjectContext) throws -> T
    ) async throws -> T {
        try await waitForStoreToLoad()

        let context = newBackgroundContext()
        context.undoManager = nil // Not needed for read-only

        return try await context.perform {
            try block(context)
        }
    }
}
