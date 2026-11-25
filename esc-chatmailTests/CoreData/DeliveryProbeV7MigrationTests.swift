import CoreData
import XCTest
@testable import esc_chatmail

/// A v6 store must migrate to v7 with its send-recovery records intact, and
/// every record it held has no admission time: the "Delivery unknown" probe
/// never resolves a send admitted before model 7.
@MainActor
final class DeliveryProbeV7MigrationTests: XCTestCase {
    func testV6SQLiteStore_lightweightMigratesToV7_keepsRecordsAndLeavesThemUnprobeable() throws {
        let currentModel = CoreDataStack.shared.persistentContainer.managedObjectModel
        for key in ["admittedAt", "deliveryProbedAt"] {
            let attribute = try XCTUnwrap(
                currentModel.entitiesByName["OutboundSendMutationRecord"]?.attributesByName[key]
            )
            XCTAssertEqual(attribute.attributeType, .dateAttributeType)
            XCTAssertTrue(attribute.isOptional)
            XCTAssertNil(attribute.defaultValue)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeliveryProbeV7Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("ESCChatmail.sqlite")
        let recordID = "v6-outbound-\(UUID().uuidString)"
        let createdAt = Date(timeIntervalSince1970: 1_780_000_000)

        // Both model versions name the same managed-object subclasses. Only
        // entity-name insertion and KVC are safe while the historical model is alive.
        try autoreleasepool {
            let previousModel = try loadModel(named: "ESCChatmail 6")
            XCTAssertNil(previousModel.entitiesByName["OutboundSendMutationRecord"]?.attributesByName["admittedAt"])
            let container = try open(model: previousModel, at: storeURL, migratesAutomatically: false)
            let record = NSEntityDescription.insertNewObject(
                forEntityName: "OutboundSendMutationRecord",
                into: container.viewContext
            )
            record.setValue(recordID, forKey: "id")
            record.setValue(createdAt, forKey: "createdAt")
            record.setValue(OutboundSendRemoteState.ambiguousMessageID, forKey: "remoteCommittedMessageId")
            try container.viewContext.save()
            try removeStores(from: container)
        }

        let admittedAt = Date(timeIntervalSince1970: 1_790_000_000)
        try autoreleasepool {
            let container = try open(model: currentModel, at: storeURL, migratesAutomatically: true)
            let record = try fetchRecord(id: recordID, in: container.viewContext)
            XCTAssertEqual(record.createdAt, createdAt)
            XCTAssertEqual(record.remoteCommittedMessageId, OutboundSendRemoteState.ambiguousMessageID)
            XCTAssertNil(record.admittedAt)
            XCTAssertNil(record.deliveryProbedAt)
            XCTAssertFalse(
                DeliveryUnknownProbePolicy.isEligible(
                    .init(
                        optimisticMessageID: record.id,
                        remoteCommittedMessageId: record.remoteCommittedMessageId,
                        remoteCommittedThreadId: record.remoteCommittedThreadId,
                        admittedAt: record.admittedAt,
                        deliveryProbedAt: record.deliveryProbedAt
                    ),
                    runStartedAt: Date()
                ),
                "A send admitted before model 7 is never resolved by the probe"
            )
            record.deliveryProbedAt = admittedAt
            try container.viewContext.save()
            try removeStores(from: container)
        }

        let reopened = try open(model: currentModel, at: storeURL, migratesAutomatically: false)
        XCTAssertEqual(try fetchRecord(id: recordID, in: reopened.viewContext).deliveryProbedAt, admittedAt)
        try removeStores(from: reopened)
    }

    private func fetchRecord(id: String, in context: NSManagedObjectContext) throws -> OutboundSendMutationRecord {
        let request = NSFetchRequest<OutboundSendMutationRecord>(entityName: "OutboundSendMutationRecord")
        request.predicate = NSPredicate(format: "id == %@", id)
        return try XCTUnwrap(context.fetch(request).first)
    }

    private func loadModel(named name: String) throws -> NSManagedObjectModel {
        let bundles = [Bundle(for: CoreDataStack.self), Bundle.main]
        let modelDirectory = try XCTUnwrap(bundles.lazy.compactMap {
            $0.url(forResource: "ESCChatmail", withExtension: "momd")
        }.first)
        return try XCTUnwrap(NSManagedObjectModel(
            contentsOf: modelDirectory.appendingPathComponent(name).appendingPathExtension("mom")
        ))
    }

    private func open(
        model: NSManagedObjectModel,
        at storeURL: URL,
        migratesAutomatically: Bool
    ) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "DeliveryProbeMigration", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = migratesAutomatically
        description.shouldInferMappingModelAutomatically = migratesAutomatically
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        return container
    }

    private func removeStores(from container: NSPersistentContainer) throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
}
