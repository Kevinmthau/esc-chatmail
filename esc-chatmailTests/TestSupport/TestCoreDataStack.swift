import Foundation
import CoreData
@testable import esc_chatmail

/// In-memory Core Data stack for unit testing.
/// Provides fast, isolated storage that resets between tests.
final class TestCoreDataStack: @unchecked Sendable {

    let persistentContainer: NSPersistentContainer

    /// Creates a new in-memory Core Data stack.
    /// Each instance has its own isolated storage.
    init() {
        let container = NSPersistentContainer(name: "ESCChatmail")

        // Use in-memory store for fast, isolated tests
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                fatalError("Failed to load in-memory Core Data store: \(error)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        self.persistentContainer = container
    }

    /// Main thread context for UI operations in tests
    var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }

    /// Creates a new background context for testing background operations
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    /// Saves the view context if it has changes
    func saveViewContext() throws {
        guard viewContext.hasChanges else { return }
        try viewContext.save()
    }

    /// Resets the view context, discarding all unsaved changes
    func resetViewContext() {
        viewContext.reset()
    }

    /// Performs a task in a background context and saves
    func performBackgroundTask<T>(_ block: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            persistentContainer.performBackgroundTask { context in
                context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
                do {
                    let result = try block(context)
                    if context.hasChanges {
                        try context.save()
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Save Operations (matching CoreDataStack extension)

    /// Convenience method for saves that logs errors but doesn't throw
    /// - Parameters:
    ///   - context: The managed object context to save
    ///   - caller: Optional identifier for debugging
    /// - Returns: true if save succeeded or no changes were needed
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
            } catch {
                saveSucceeded = false
            }
        }

        return saveSucceeded
    }

    /// Async version of saveIfNeeded
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
            } catch {
                completion?(false)
            }
        }
    }
}
