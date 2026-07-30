import CoreData
import XCTest
@testable import esc_chatmail

/// Pins the v2 ("ListIdV2") → v3 ("SyncDurabilityV3") lightweight migration:
/// AbandonedSyncMessage gains four optional deferral columns and the
/// SyncCheckpoint entity is new. A store written with the bundled v2 model
/// must open under the current model with rows intact — most critically the
/// AbandonedSyncMessage ledger and the PendingAction/OutboundSendMutationRecord
/// rows the recovery ladder would otherwise destroy.
@MainActor
final class SyncDurabilityV3MigrationTests: XCTestCase {

    func testV2SQLiteStoreLightweightMigratesAndPreservesRows() throws {
        let currentModel = CoreDataStack.shared.persistentContainer.managedObjectModel
        // Sanity: the loaded model is v3-shaped.
        XCTAssertNotNil(currentModel.entitiesByName["AbandonedSyncMessage"]?.attributesByName["state"])
        XCTAssertNotNil(currentModel.entitiesByName["SyncCheckpoint"])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncDurabilityV3Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("ESCChatmail.sqlite")

        try autoreleasepool {
            let v2Model = try loadBundledModel(named: "ESCChatmail 2")
            XCTAssertNil(
                v2Model.entitiesByName["AbandonedSyncMessage"]?.attributesByName["state"],
                "The bundled v2 model must predate the deferral columns or this test is vacuous"
            )
            XCTAssertNil(v2Model.entitiesByName["SyncCheckpoint"])
            try writeV2Store(model: v2Model, storeURL: storeURL)
        }
        try migrateAndVerifyStore(model: currentModel, storeURL: storeURL)
    }

    /// The bundled v2 model must stay in the app bundle: lightweight migration
    /// finds its source model by matching store metadata against every bundled
    /// version, and a rollback build must also retain v3's files or downgraded
    /// stores hit the missing-source wipe.
    func testAllModelVersionsRemainBundled() throws {
        let momd = try modelDirectory()
        for version in ["ESCChatmail", "ESCChatmail 2", "ESCChatmail 3"] {
            let url = momd.appendingPathComponent(version).appendingPathExtension("mom")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(version).mom missing from the bundle — upgrading stores would have no migration source"
            )
        }
    }

    // MARK: - Helpers

    private func modelDirectory() throws -> URL {
        let candidateBundles = [Bundle(for: CoreDataStack.self), Bundle.main]
        return try XCTUnwrap(
            candidateBundles.lazy.compactMap {
                $0.url(forResource: "ESCChatmail", withExtension: "momd")
            }.first,
            "The versioned ESCChatmail.momd must be compiled into the host app"
        )
    }

    private func loadBundledModel(named name: String) throws -> NSManagedObjectModel {
        let url = try modelDirectory()
            .appendingPathComponent(name)
            .appendingPathExtension("mom")
        return try XCTUnwrap(NSManagedObjectModel(contentsOf: url))
    }

    private func writeV2Store(model: NSManagedObjectModel, storeURL: URL) throws {
        let container = NSPersistentContainer(name: "V2ESCChatmail", managedObjectModel: model)
        try loadSQLiteStore(into: container, at: storeURL, migratesAutomatically: false)

        let context = container.viewContext

        let abandoned = NSEntityDescription.insertNewObject(
            forEntityName: "AbandonedSyncMessage",
            into: context
        )
        abandoned.setValue(UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444"), forKey: "id")
        abandoned.setValue("abandoned-gmail-id", forKey: "gmailMessageId")
        abandoned.setValue(Date(timeIntervalSince1970: 1_750_000_000), forKey: "abandonedAt")
        abandoned.setValue("fetch_failed", forKey: "reason")
        abandoned.setValue(Int16(2), forKey: "retryCount")

        let pendingAction = NSEntityDescription.insertNewObject(
            forEntityName: "PendingAction",
            into: context
        )
        pendingAction.setValue(UUID(uuidString: "BBBBBBBB-1111-2222-3333-444444444444"), forKey: "id")
        pendingAction.setValue("archive", forKey: "actionType")
        pendingAction.setValue(Date(timeIntervalSince1970: 1_750_000_001), forKey: "createdAt")
        pendingAction.setValue("pending", forKey: "status")
        pendingAction.setValue("v2-message", forKey: "messageId")

        let mutationRecord = NSEntityDescription.insertNewObject(
            forEntityName: "OutboundSendMutationRecord",
            into: context
        )
        mutationRecord.setValue("v2-outbound-record", forKey: "id")
        mutationRecord.setValue(Date(timeIntervalSince1970: 1_750_000_002), forKey: "createdAt")
        mutationRecord.setValue(false, forKey: "newlyInsertedConversation")
        mutationRecord.setValue(false, forKey: "hidden")

        try context.save()
        try removeStore(from: container)
    }

    private func migrateAndVerifyStore(model: NSManagedObjectModel, storeURL: URL) throws {
        let container = NSPersistentContainer(name: "V3ESCChatmail", managedObjectModel: model)
        try loadSQLiteStore(into: container, at: storeURL, migratesAutomatically: true)

        let context = container.viewContext

        let abandonedRequest = NSFetchRequest<NSManagedObject>(entityName: "AbandonedSyncMessage")
        abandonedRequest.predicate = NSPredicate(format: "gmailMessageId == %@", "abandoned-gmail-id")
        let abandoned = try XCTUnwrap(context.fetch(abandonedRequest).first)
        XCTAssertEqual(abandoned.value(forKey: "retryCount") as? Int16, 2, "Ledger state must survive")
        XCTAssertEqual(abandoned.value(forKey: "reason") as? String, "fetch_failed")
        XCTAssertNil(abandoned.value(forKey: "state"), "New columns default to nil on migrated rows")
        XCTAssertNil(abandoned.value(forKey: "failureClass"))
        XCTAssertNil(abandoned.value(forKey: "sourceHistoryId"))
        XCTAssertNil(abandoned.value(forKey: "nextRetryAt"))

        XCTAssertEqual(
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "PendingAction")),
            1,
            "PendingAction rows are the non-re-syncable data the migration must carry"
        )
        XCTAssertEqual(
            try context.count(
                for: NSFetchRequest<NSFetchRequestResult>(entityName: "OutboundSendMutationRecord")
            ),
            1
        )

        // The new columns and entity are writable post-migration.
        abandoned.setValue("deferred", forKey: "state")
        abandoned.setValue("quota", forKey: "failureClass")

        let checkpoint = NSEntityDescription.insertNewObject(
            forEntityName: "SyncCheckpoint",
            into: context
        )
        checkpoint.setValue(UUID(), forKey: "id")
        checkpoint.setValue("me@example.com", forKey: "accountEmail")
        checkpoint.setValue("incremental", forKey: "kind")
        checkpoint.setValue(Date(timeIntervalSince1970: 1_750_000_003), forKey: "createdAt")
        checkpoint.setValue(Date(timeIntervalSince1970: 1_750_000_003), forKey: "updatedAt")
        try context.save()
        context.reset()

        let savedAbandoned = try XCTUnwrap(context.fetch(abandonedRequest).first)
        XCTAssertEqual(savedAbandoned.value(forKey: "state") as? String, "deferred")
        XCTAssertEqual(savedAbandoned.value(forKey: "failureClass") as? String, "quota")
        XCTAssertEqual(
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "SyncCheckpoint")),
            1
        )

        try removeStore(from: container)
    }

    private func loadSQLiteStore(
        into container: NSPersistentContainer,
        at storeURL: URL,
        migratesAutomatically: Bool
    ) throws {
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = migratesAutomatically
        description.shouldInferMappingModelAutomatically = migratesAutomatically
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        if let loadError {
            throw loadError
        }
    }

    private func removeStore(from container: NSPersistentContainer) throws {
        guard let store = container.persistentStoreCoordinator.persistentStores.first else {
            return
        }
        try container.persistentStoreCoordinator.remove(store)
    }
}
