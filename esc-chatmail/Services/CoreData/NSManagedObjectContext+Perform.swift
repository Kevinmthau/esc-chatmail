import Foundation
import CoreData

// MARK: - Async Perform Helpers

/// Async wrappers for Core Data operations that properly use context.perform()
/// These build on the synchronous helpers in NSManagedObjectContext+Fetch.swift
extension NSManagedObjectContext {

    // MARK: - Fetch Operations

    /// Performs a fetch for the first matching entity on the context's queue
    /// - Parameters:
    ///   - type: The NSManagedObject subclass to fetch
    ///   - predicate: Optional predicate to filter results
    ///   - sortDescriptors: Optional sort descriptors
    /// - Returns: The first matching entity, or nil if none found or error occurred
    func performFetchFirst<T: NSManagedObject>(
        _ type: T.Type,
        where predicate: NSPredicate? = nil,
        sortedBy sortDescriptors: [NSSortDescriptor]? = nil
    ) async -> T? {
        await perform {
            try? self.fetchFirst(type, where: predicate, sortedBy: sortDescriptors)
        }
    }

    /// Performs a fetch for the first matching entity, throwing on error
    /// - Parameters:
    ///   - type: The NSManagedObject subclass to fetch
    ///   - predicate: Optional predicate to filter results
    ///   - sortDescriptors: Optional sort descriptors
    /// - Returns: The first matching entity, or nil if none found
    /// - Throws: Core Data fetch errors
    func performFetchFirstThrowing<T: NSManagedObject>(
        _ type: T.Type,
        where predicate: NSPredicate? = nil,
        sortedBy sortDescriptors: [NSSortDescriptor]? = nil
    ) async throws -> T? {
        try await perform {
            try self.fetchFirst(type, where: predicate, sortedBy: sortDescriptors)
        }
    }

    /// Performs a fetch for all matching entities on the context's queue
    /// - Parameters:
    ///   - type: The NSManagedObject subclass to fetch
    ///   - predicate: Optional predicate to filter results
    ///   - sortDescriptors: Optional sort descriptors
    ///   - limit: Optional fetch limit
    /// - Returns: Array of matching entities, or empty array on error
    func performFetchAll<T: NSManagedObject>(
        _ type: T.Type,
        where predicate: NSPredicate? = nil,
        sortedBy sortDescriptors: [NSSortDescriptor]? = nil,
        limit: Int? = nil
    ) async -> [T] {
        await perform {
            (try? self.fetchAll(type, where: predicate, sortedBy: sortDescriptors, limit: limit)) ?? []
        }
    }

    /// Performs a fetch for all matching entities, throwing on error
    /// - Parameters:
    ///   - type: The NSManagedObject subclass to fetch
    ///   - predicate: Optional predicate to filter results
    ///   - sortDescriptors: Optional sort descriptors
    ///   - limit: Optional fetch limit
    /// - Returns: Array of matching entities
    /// - Throws: Core Data fetch errors
    func performFetchAllThrowing<T: NSManagedObject>(
        _ type: T.Type,
        where predicate: NSPredicate? = nil,
        sortedBy sortDescriptors: [NSSortDescriptor]? = nil,
        limit: Int? = nil
    ) async throws -> [T] {
        try await perform {
            try self.fetchAll(type, where: predicate, sortedBy: sortDescriptors, limit: limit)
        }
    }

    /// Performs a count operation on the context's queue
    /// - Parameters:
    ///   - type: The NSManagedObject subclass to count
    ///   - predicate: Optional predicate to filter
    /// - Returns: Count of matching entities, or 0 on error
    func performCount<T: NSManagedObject>(
        _ type: T.Type,
        where predicate: NSPredicate? = nil
    ) async -> Int {
        await perform {
            (try? self.count(type, where: predicate)) ?? 0
        }
    }

    // MARK: - Update Operations

    /// Performs an update on a single entity matching the predicate
    /// - Parameters:
    ///   - type: The NSManagedObject subclass to update
    ///   - predicate: Predicate to find the entity
    ///   - update: Closure to perform updates on the entity
    /// - Returns: true if entity was found and updated, false otherwise
    @discardableResult
    func performUpdate<T: NSManagedObject>(
        _ type: T.Type,
        where predicate: NSPredicate,
        update: @escaping (T) -> Void
    ) async -> Bool {
        await perform {
            guard let entity = try? self.fetchFirst(type, where: predicate) else {
                return false
            }
            update(entity)
            return true
        }
    }

    /// Performs updates on all entities matching the predicate
    /// - Parameters:
    ///   - type: The NSManagedObject subclass to update
    ///   - predicate: Optional predicate to filter entities
    ///   - update: Closure to perform updates on each entity
    /// - Returns: Number of entities updated
    @discardableResult
    func performBatchUpdate<T: NSManagedObject>(
        _ type: T.Type,
        where predicate: NSPredicate? = nil,
        update: @escaping (T) -> Void
    ) async -> Int {
        await perform {
            let entities = (try? self.fetchAll(type, where: predicate)) ?? []
            for entity in entities {
                update(entity)
            }
            return entities.count
        }
    }

    // MARK: - Delete Operations

    /// Deletes all entities matching the predicate
    /// - Parameters:
    ///   - type: The NSManagedObject subclass to delete
    ///   - predicate: Predicate to filter entities to delete
    /// - Returns: Number of entities deleted
    @discardableResult
    func performDelete<T: NSManagedObject>(
        _ type: T.Type,
        where predicate: NSPredicate
    ) async -> Int {
        await perform {
            let entities = (try? self.fetchAll(type, where: predicate)) ?? []
            for entity in entities {
                self.delete(entity)
            }
            return entities.count
        }
    }

    // MARK: - Save Operations

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

    // MARK: - Combined Operations

    /// Performs an update and saves in a single operation
    /// - Parameters:
    ///   - type: The NSManagedObject subclass to update
    ///   - predicate: Predicate to find the entity
    ///   - update: Closure to perform updates on the entity
    ///   - caller: Description of the calling context for logging
    /// - Returns: true if entity was found, updated, and saved successfully
    @discardableResult
    func performUpdateAndSave<T: NSManagedObject>(
        _ type: T.Type,
        where predicate: NSPredicate,
        update: @escaping (T) -> Void,
        caller: String = #function
    ) async -> Bool {
        await perform {
            guard let entity = try? self.fetchFirst(type, where: predicate) else {
                return false
            }
            update(entity)

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

    /// Fetches an existing object by ID on the context's queue
    /// - Parameter objectID: The NSManagedObjectID to fetch
    /// - Returns: The object, or nil if not found or error occurred
    func performFetchExisting<T: NSManagedObject>(_ objectID: NSManagedObjectID) async -> T? {
        await perform {
            try? self.existingObject(with: objectID) as? T
        }
    }
}
