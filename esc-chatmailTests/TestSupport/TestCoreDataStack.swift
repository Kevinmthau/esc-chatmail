import Foundation
import CoreData
@testable import esc_chatmail

/// In-memory Core Data stack for unit testing.
/// Provides fast, isolated storage that resets between tests.
final class TestCoreDataStack: @unchecked Sendable {

    /// The single `NSManagedObjectModel` instance for the whole test process —
    /// the same instance the host app's `CoreDataStack.shared` loaded at launch
    /// (the app skips its runtime uniqueness-constraint mutation under XCTest,
    /// so this model keeps the constraint-free semantics tests rely on).
    ///
    /// One model per process matters twice over:
    /// - `NSPersistentContainer(name:)` would load a fresh model per test
    ///   stack, and every load/dealloc re-registers entity↔class mappings in
    ///   Core Data's process-global tables — racing any concurrent Core Data
    ///   work (async test bodies run off the main thread) and intermittently
    ///   crashing inside the fixture builders under parallel testing.
    /// - With even two stable model instances alive, `+[NSManagedObject
    ///   entity]` cannot disambiguate ("Failed to find a unique match"), which
    ///   breaks product code using `Entity(context:)` initializers.
    private static let sharedModel: NSManagedObjectModel =
        CoreDataStack.shared.persistentContainer.managedObjectModel

    /// Serializes container creation. Coordinator↔model association is not
    /// guaranteed thread-safe for concurrent first-touch bookkeeping, and with
    /// parallel testing test classes run concurrently in one process, so
    /// stacks are created from several threads at once (class setUp on the
    /// main thread, in-body stacks on cooperative threads).
    private static let creationLock = NSLock()

    /// Containers and test view contexts are never deallocated: they retire
    /// here when their stack is torn down. Async work leaked by a test
    /// (delayed scheme-handler fallbacks, utility-priority prefetch tasks)
    /// can outlive the test while holding managed objects or
    /// `newBackgroundContext` closures from its stack. If the context or
    /// coordinator deallocated at teardown, that late work would fault
    /// objects of a deallocating context (crashing in
    /// `-[NSManagedObjectContext _dispose:]` on the context's queue) or tear
    /// down the store under other tests. Retired stacks stay alive and idle,
    /// so late work pokes its own retired store instead of a live test's.
    private static var graveyard: [AnyObject] = []

    let persistentContainer: NSPersistentContainer

    /// Backing store flavor for a test stack.
    enum StoreKind {
        /// Fast, default. Does NOT support persistent history tracking.
        case inMemory
        /// Per-instance temp-file SQLite store. Mirrors the production store
        /// options (persistent history tracking ON) for tests that exercise
        /// history-dependent behavior. Divergence from production: the shared
        /// test model is constraint-free (the app skips
        /// `enforceUniquenessConstraints` under XCTest), so `Message.id` has
        /// no uniqueness constraint here even though production applies one.
        ///
        /// Cleanup: stale store files from PREVIOUS runs are swept on first
        /// use. Per-instance unlink at teardown is deliberately avoided — the
        /// graveyard keeps retired store connections open, and unlinking an
        /// in-use vnode is a libsqlite3 API violation that invalidates the
        /// open file descriptors under every retired stack.
        case sqlite
    }

    /// One-time, best-effort sweep of temp-store files left by previous test
    /// runs. Age-gated so a concurrently running sibling test process (Xcode
    /// parallel testing) never loses its live stores.
    private static let staleStoreSweep: Void = {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in entries where url.lastPathComponent.hasPrefix("TestCoreDataStack-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }()

    /// Creates a new isolated Core Data stack.
    /// Each instance has its own isolated storage (stores are per-container;
    /// only the immutable model object is shared).
    ///
    /// - Parameters:
    ///   - automaticallyMergesChanges: Opt-in automerge for the test
    ///     view context. Default is OFF because automerge applies sibling saves
    ///     as async blocks on the view context's queue, racing the test body's
    ///     direct access from the cooperative thread. Enable only for tests that
    ///     specifically verify merge-driven behavior (e.g. view-model refresh on
    ///     background saves) and tolerate that window.
    ///   - storeKind: `.inMemory` (default) or `.sqlite` for tests needing
    ///     store features the in-memory type lacks (persistent history).
    init(automaticallyMergesChanges: Bool = false, storeKind: StoreKind = .inMemory) {
        Self.creationLock.lock()
        let container = NSPersistentContainer(name: "ESCChatmail", managedObjectModel: Self.sharedModel)
        Self.creationLock.unlock()

        let description = NSPersistentStoreDescription()
        switch storeKind {
        case .inMemory:
            description.type = NSInMemoryStoreType
        case .sqlite:
            _ = Self.staleStoreSweep
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("TestCoreDataStack-\(UUID().uuidString)")
                .appendingPathExtension("sqlite")
            description.type = NSSQLiteStoreType
            description.url = url
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        }
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                fatalError("Failed to load test Core Data store: \(error)")
            }
        }

        self.persistentContainer = container

        // The test "view context" is a private-queue context, NOT the
        // container's main-queue viewContext. Main-queue contexts process
        // pending changes from a main-run-loop observer; async test bodies
        // mutate their contexts from cooperative threads, so with parallel
        // testing keeping the main run loop busy, that observer fires
        // concurrently with the test's own inserts/deletes and intermittently
        // loses pending changes or corrupts the context (the random
        // fixture-builder crashes and "Cannot save objects with references
        // outside of their own stores" save failures). A private-queue context
        // has no run-loop integration and is touched only by its own test.
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = container.persistentStoreCoordinator
        // Automerge is OFF by default: it applies sibling saves as async
        // blocks on this context's queue, concurrent with the test body's
        // direct (lock-free) access from the cooperative thread. Tests that
        // need view-context visibility of a background save refresh explicitly
        // (refreshAllObjects / re-fetch) or opt in via the initializer.
        context.automaticallyMergesChangesFromParent = automaticallyMergesChanges
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        self.testViewContext = context
    }

    deinit {
        Self.creationLock.lock()
        Self.graveyard.append(persistentContainer)
        Self.graveyard.append(testViewContext)
        Self.creationLock.unlock()
    }

    /// The context tests treat as their "view context". Backed by a
    /// private-queue context so it has no main-run-loop integration; see init.
    private let testViewContext: NSManagedObjectContext

    /// Primary context for test fixtures and assertions.
    var viewContext: NSManagedObjectContext {
        testViewContext
    }

    /// Creates a new background context for testing background operations
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    /// Saves the view context if it has changes.
    ///
    /// Serialized via `performAndWait`: test bodies run on cooperative threads
    /// while code under test mutates this context inside `context.perform`
    /// blocks on its private queue. A direct off-queue `save()` after such a
    /// block intermittently misses pending changes (deletes/inserts silently
    /// dropped from the save). `performAndWait` takes the context's queue and
    /// the right memory barriers, and is legal from any thread.
    func saveViewContext() throws {
        try viewContext.performAndWait {
            guard viewContext.hasChanges else { return }
            try viewContext.save()
        }
    }

    /// Resets the view context, discarding all unsaved changes
    func resetViewContext() {
        viewContext.performAndWait {
            viewContext.reset()
        }
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
