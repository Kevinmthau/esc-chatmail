import CoreData
@testable import esc_chatmail

/// A main-queue context (the shape `TestCoreDataStack.makeMainQueueViewContext()`
/// makes) that records every fetch of `Message` it runs: its `fetchOffset`, and
/// the number of IDs in a `SELF IN` term of its predicate. For suites that count
/// what `VirtualScrollState` asks its view context for on the main actor, where
/// `FetchCountingContext` (private-queue, counts alone) cannot stand in.
///
/// Made through `make(retiredWith:)`, which retires it to the stack's graveyard
/// as `makeMainQueueViewContext()` retires its own: a `VirtualScrollState`'s
/// reconciles and preloads can outlive the test that made it.
///
/// Touched only on the main queue, like any main-queue context, so the record
/// needs no lock.
final class MainQueueFetchRecordingContext: NSManagedObjectContext, @unchecked Sendable {
    struct MessageFetch: Equatable {
        let fetchOffset: Int
        /// The number of IDs in the predicate's `SELF IN` term, nil where it
        /// has none.
        let selfInIDCount: Int?
    }

    private(set) var messageFetches: [MessageFetch] = []

    /// A new context on `stack`'s coordinator, retired to its graveyard.
    static func make(retiredWith stack: TestCoreDataStack) -> MainQueueFetchRecordingContext {
        let context = MainQueueFetchRecordingContext(
            coordinator: stack.persistentContainer.persistentStoreCoordinator
        )
        stack.retire(context)
        return context
    }

    private init(coordinator: NSPersistentStoreCoordinator) {
        super.init(concurrencyType: .mainQueueConcurrencyType)
        persistentStoreCoordinator = coordinator
        automaticallyMergesChangesFromParent = false
        mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    required init?(coder: NSCoder) {
        fatalError("not supported in tests")
    }

    func resetRecordedFetches() {
        messageFetches.removeAll()
    }

    /// `executeFetchRequest:error:` is `NS_REFINED_FOR_SWIFT`; the generic
    /// `fetch(_:)` overlay calls through to this underscored `__execute(_:)`.
    override func __execute(_ request: NSFetchRequest<NSFetchRequestResult>) throws -> [Any] {
        if request.entityName == "Message" {
            messageFetches.append(MessageFetch(
                fetchOffset: request.fetchOffset,
                selfInIDCount: request.predicate.flatMap(Self.selfInIDCount(in:))
            ))
        }
        return try super.__execute(request)
    }

    private static func selfInIDCount(in predicate: NSPredicate) -> Int? {
        if let compound = predicate as? NSCompoundPredicate {
            return compound.subpredicates
                .compactMap { ($0 as? NSPredicate).flatMap(selfInIDCount(in:)) }
                .first
        }
        guard let comparison = predicate as? NSComparisonPredicate,
              comparison.predicateOperatorType == .in,
              comparison.leftExpression.expressionType == .evaluatedObject,
              comparison.rightExpression.expressionType == .constantValue else {
            return nil
        }
        switch comparison.rightExpression.constantValue {
        case let array as [Any]:
            return array.count
        case let set as NSSet:
            return set.count
        default:
            return nil
        }
    }
}
