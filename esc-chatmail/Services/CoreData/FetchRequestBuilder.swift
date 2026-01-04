import Foundation
import CoreData

/// A chainable builder for creating NSFetchRequest instances with a fluent API.
///
/// Usage:
/// ```swift
/// let request = FetchRequestBuilder<Message>()
///     .where(MessagePredicates.inbox)
///     .sorted(by: NSSortDescriptor(key: "internalDate", ascending: false))
///     .limit(50)
///     .batchSize(20)
///     .build()
/// ```
struct FetchRequestBuilder<T: NSManagedObject> {

    // MARK: - Properties

    private var predicate: NSPredicate?
    private var sortDescriptors: [NSSortDescriptor]?
    private var fetchLimit: Int?
    private var fetchBatchSize: Int?
    private var fetchOffset: Int?
    private var propertiesToFetch: [String]?
    private var relationshipKeyPathsForPrefetching: [String]?
    private var resultType: NSFetchRequestResultType = .managedObjectResultType
    private var returnsObjectsAsFaults: Bool = true
    private var includesSubentities: Bool = true
    private var includesPropertyValues: Bool = true
    private var includesPendingChanges: Bool = true

    // MARK: - Initialization

    init() {}

    // MARK: - Predicate Methods

    /// Sets the predicate for the fetch request.
    func `where`(_ predicate: NSPredicate) -> FetchRequestBuilder<T> {
        var builder = self
        builder.predicate = predicate
        return builder
    }

    /// Combines the current predicate with another using AND.
    func and(_ predicate: NSPredicate) -> FetchRequestBuilder<T> {
        var builder = self
        if let existing = builder.predicate {
            builder.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [existing, predicate])
        } else {
            builder.predicate = predicate
        }
        return builder
    }

    /// Combines the current predicate with another using OR.
    func or(_ predicate: NSPredicate) -> FetchRequestBuilder<T> {
        var builder = self
        if let existing = builder.predicate {
            builder.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [existing, predicate])
        } else {
            builder.predicate = predicate
        }
        return builder
    }

    // MARK: - Sorting Methods

    /// Sets the sort descriptors for the fetch request.
    func sorted(by descriptors: NSSortDescriptor...) -> FetchRequestBuilder<T> {
        var builder = self
        builder.sortDescriptors = descriptors
        return builder
    }

    /// Sets the sort descriptors using an array.
    func sorted(by descriptors: [NSSortDescriptor]) -> FetchRequestBuilder<T> {
        var builder = self
        builder.sortDescriptors = descriptors
        return builder
    }

    /// Sorts by a single key path.
    func sorted<Value>(by keyPath: KeyPath<T, Value>, ascending: Bool = true) -> FetchRequestBuilder<T> {
        var builder = self
        let descriptor = NSSortDescriptor(keyPath: keyPath, ascending: ascending)
        builder.sortDescriptors = [descriptor]
        return builder
    }

    // MARK: - Limit & Offset Methods

    /// Sets the maximum number of objects to fetch.
    func limit(_ count: Int) -> FetchRequestBuilder<T> {
        var builder = self
        builder.fetchLimit = count
        return builder
    }

    /// Sets the batch size for fetching.
    func batchSize(_ size: Int) -> FetchRequestBuilder<T> {
        var builder = self
        builder.fetchBatchSize = size
        return builder
    }

    /// Sets the offset for pagination.
    func offset(_ offset: Int) -> FetchRequestBuilder<T> {
        var builder = self
        builder.fetchOffset = offset
        return builder
    }

    // MARK: - Prefetching Methods

    /// Sets relationships to prefetch.
    func prefetching(_ relationships: [String]) -> FetchRequestBuilder<T> {
        var builder = self
        builder.relationshipKeyPathsForPrefetching = relationships
        return builder
    }

    /// Sets specific properties to fetch (partial fetch).
    func properties(_ propertyNames: [String]) -> FetchRequestBuilder<T> {
        var builder = self
        builder.propertiesToFetch = propertyNames
        return builder
    }

    // MARK: - Result Configuration

    /// Sets the result type for the fetch request.
    func resultType(_ type: NSFetchRequestResultType) -> FetchRequestBuilder<T> {
        var builder = self
        builder.resultType = type
        return builder
    }

    /// Configures whether to return objects as faults.
    func returnsAsFaults(_ value: Bool) -> FetchRequestBuilder<T> {
        var builder = self
        builder.returnsObjectsAsFaults = value
        return builder
    }

    /// Configures whether to include subentities.
    func includesSubentities(_ value: Bool) -> FetchRequestBuilder<T> {
        var builder = self
        builder.includesSubentities = value
        return builder
    }

    /// Configures whether to include property values.
    func includesPropertyValues(_ value: Bool) -> FetchRequestBuilder<T> {
        var builder = self
        builder.includesPropertyValues = value
        return builder
    }

    /// Configures whether to include pending changes.
    func includesPendingChanges(_ value: Bool) -> FetchRequestBuilder<T> {
        var builder = self
        builder.includesPendingChanges = value
        return builder
    }

    // MARK: - Build Methods

    /// Builds and returns the configured NSFetchRequest.
    func build() -> NSFetchRequest<T> {
        let request = NSFetchRequest<T>(entityName: String(describing: T.self))

        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        request.resultType = resultType
        request.returnsObjectsAsFaults = returnsObjectsAsFaults
        request.includesSubentities = includesSubentities
        request.includesPropertyValues = includesPropertyValues
        request.includesPendingChanges = includesPendingChanges

        if let limit = fetchLimit {
            request.fetchLimit = limit
        }

        if let batchSize = fetchBatchSize {
            request.fetchBatchSize = batchSize
        }

        if let offset = fetchOffset {
            request.fetchOffset = offset
        }

        if let properties = propertiesToFetch {
            request.propertiesToFetch = properties
        }

        if let prefetchKeys = relationshipKeyPathsForPrefetching {
            request.relationshipKeyPathsForPrefetching = prefetchKeys
        }

        return request
    }

    /// Builds a fetch request for dictionary results.
    func buildForDictionary() -> NSFetchRequest<NSFetchRequestResult> {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: String(describing: T.self))

        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        request.resultType = .dictionaryResultType
        request.includesPendingChanges = includesPendingChanges

        if let limit = fetchLimit {
            request.fetchLimit = limit
        }

        if let batchSize = fetchBatchSize {
            request.fetchBatchSize = batchSize
        }

        if let offset = fetchOffset {
            request.fetchOffset = offset
        }

        if let properties = propertiesToFetch {
            request.propertiesToFetch = properties
        }

        return request
    }

    /// Builds a fetch request for counting.
    func buildForCount() -> NSFetchRequest<NSNumber> {
        let request = NSFetchRequest<NSNumber>(entityName: String(describing: T.self))

        request.predicate = predicate
        request.resultType = .countResultType
        request.includesPendingChanges = includesPendingChanges

        return request
    }
}

// MARK: - Convenience Extensions

extension FetchRequestBuilder {

    /// Creates a builder configured for fetching a single object.
    static func first() -> FetchRequestBuilder<T> {
        FetchRequestBuilder<T>().limit(1)
    }

    /// Creates a builder with common list configuration.
    static func list(batchSize: Int = 20) -> FetchRequestBuilder<T> {
        FetchRequestBuilder<T>()
            .batchSize(batchSize)
            .returnsAsFaults(true)
    }

    /// Creates a builder for efficient batch operations.
    static func batch(size: Int = 100) -> FetchRequestBuilder<T> {
        FetchRequestBuilder<T>()
            .batchSize(size)
            .returnsAsFaults(false)
            .includesPropertyValues(true)
    }
}
