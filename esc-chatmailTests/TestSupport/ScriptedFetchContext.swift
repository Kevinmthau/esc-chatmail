import Foundation
import CoreData
@testable import esc_chatmail

/// An incremental store whose every request throws, driving Core Data
/// read-failure paths deterministically at the store level (a store-less
/// coordinator returns [] silently, and the Swift `fetch` shim cannot be
/// overridden). Companion to `ScriptedSaveContext`.
final class FailingReadStore: NSIncrementalStore {
    static let storeType = "esc-chatmailTests.FailingReadStore"

    private static let registerOnce: Void = {
        NSPersistentStoreCoordinator.registerStoreClass(
            FailingReadStore.self,
            type: NSPersistentStore.StoreType(rawValue: storeType)
        )
    }()

    override var type: String {
        Self.storeType
    }

    override func loadMetadata() throws {
        metadata = [
            NSStoreTypeKey: Self.storeType,
            NSStoreUUIDKey: UUID().uuidString,
        ]
    }

    override func execute(
        _ request: NSPersistentStoreRequest,
        with context: NSManagedObjectContext?
    ) throws -> Any {
        throw NSError(
            domain: "FailingReadStore",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "scripted store failure"]
        )
    }

    /// Builds a private-queue context backed solely by a failing store, using
    /// the process-shared model (see TestCoreDataStack's single-model rule).
    static func makeFailingContext() throws -> NSManagedObjectContext {
        _ = registerOnce
        let model = CoreDataStack.shared.persistentContainer.managedObjectModel
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        _ = try coordinator.addPersistentStore(
            type: NSPersistentStore.StoreType(rawValue: storeType),
            at: URL(fileURLWithPath: "/dev/null/failing-read-store-\(UUID().uuidString)")
        )
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    /// A persistent container backed solely by a failing store, for injecting
    /// store-level failures into components that create their own contexts
    /// (e.g. via `CoreDataStack(persistentContainerForTesting:)`).
    static func makeFailingContainer() -> NSPersistentContainer {
        _ = registerOnce
        let model = CoreDataStack.shared.persistentContainer.managedObjectModel
        let container = NSPersistentContainer(name: "ESCChatmail", managedObjectModel: model)
        let description = NSPersistentStoreDescription(
            url: URL(fileURLWithPath: "/dev/null/failing-read-store-\(UUID().uuidString)")
        )
        description.type = storeType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            precondition(error == nil, "FailingReadStore must load; requests fail, not the store itself")
        }
        return container
    }
}
