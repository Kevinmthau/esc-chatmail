import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class ListIdOptionalAttributeMigrationTests: XCTestCase {
    func testPreListIdSQLiteStoreLightweightMigratesAndPreservesRows() throws {
        let currentModel = CoreDataStack.shared.persistentContainer.managedObjectModel
        XCTAssertNotNil(currentModel.entitiesByName["Message"]?.attributesByName["listId"])
        XCTAssertNotNil(currentModel.entitiesByName["Conversation"]?.attributesByName["listId"])
        XCTAssertNotNil(currentModel.entitiesByName["Message"]?.attributesByName["replyTo"])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ListIdOptionalAttributeMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("ESCChatmail.sqlite")

        try autoreleasepool {
            let legacyModel = try loadBundledLegacyModel()
            XCTAssertNil(legacyModel.entitiesByName["Message"]?.attributesByName["listId"])
            XCTAssertNil(legacyModel.entitiesByName["Conversation"]?.attributesByName["listId"])
            XCTAssertNil(legacyModel.entitiesByName["Message"]?.attributesByName["replyTo"])
            try writeLegacyStore(model: legacyModel, storeURL: storeURL)
        }
        try migrateAndVerifyStore(model: currentModel, storeURL: storeURL)
    }

    func testProductionStoreDescriptionEnablesLightweightMigration() {
        let description = CoreDataStack.shared.persistentContainer
            .persistentStoreDescriptions
            .first

        XCTAssertEqual(description?.shouldMigrateStoreAutomatically, true)
        XCTAssertEqual(description?.shouldInferMappingModelAutomatically, true)
    }

    private func loadBundledLegacyModel() throws -> NSManagedObjectModel {
        let candidateBundles = [Bundle(for: CoreDataStack.self), Bundle.main]
        let modelDirectory = try XCTUnwrap(
            candidateBundles.lazy.compactMap {
                $0.url(forResource: "ESCChatmail", withExtension: "momd")
            }.first,
            "The versioned ESCChatmail.momd must be compiled into the host app"
        )
        let legacyModelURL = modelDirectory
            .appendingPathComponent("ESCChatmail")
            .appendingPathExtension("mom")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacyModelURL.path),
            "The previously shipped model must remain bundled for cold upgrades"
        )
        return try XCTUnwrap(NSManagedObjectModel(contentsOf: legacyModelURL))
    }

    private func writeLegacyStore(
        model: NSManagedObjectModel,
        storeURL: URL
    ) throws {
        let container = NSPersistentContainer(
            name: "LegacyESCChatmail",
            managedObjectModel: model
        )
        try loadSQLiteStore(
            into: container,
            at: storeURL,
            migratesAutomatically: false
        )

        let context = container.viewContext
        let conversation = NSEntityDescription.insertNewObject(
            forEntityName: "Conversation",
            into: context
        )
        conversation.setValue(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"), forKey: "id")
        conversation.setValue("legacy-key", forKey: "keyHash")
        conversation.setValue(ConversationType.oneToOne.rawValue, forKey: "type")
        conversation.setValue(true, forKey: "pinned")

        let message = NSEntityDescription.insertNewObject(
            forEntityName: "Message",
            into: context
        )
        message.setValue("legacy-message", forKey: "id")
        message.setValue("legacy-thread", forKey: "gmThreadId")
        message.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "internalDate")
        message.setValue("legacy-body", forKey: "snippet")
        message.setValue(conversation, forKey: "conversation")

        let pendingAction = NSEntityDescription.insertNewObject(
            forEntityName: "PendingAction",
            into: context
        )
        pendingAction.setValue(UUID(uuidString: "11111111-2222-3333-4444-555555555555"), forKey: "id")
        pendingAction.setValue("archive", forKey: "actionType")
        pendingAction.setValue(Date(timeIntervalSince1970: 1_700_000_001), forKey: "createdAt")
        pendingAction.setValue("pending", forKey: "status")
        pendingAction.setValue("legacy-message", forKey: "messageId")

        let mutationRecord = NSEntityDescription.insertNewObject(
            forEntityName: "OutboundSendMutationRecord",
            into: context
        )
        mutationRecord.setValue("legacy-outbound-record", forKey: "id")
        mutationRecord.setValue(Date(timeIntervalSince1970: 1_700_000_002), forKey: "createdAt")
        mutationRecord.setValue(false, forKey: "newlyInsertedConversation")
        mutationRecord.setValue(false, forKey: "hidden")

        try context.save()
        try removeStore(from: container)
    }

    private func migrateAndVerifyStore(
        model: NSManagedObjectModel,
        storeURL: URL
    ) throws {
        let container = NSPersistentContainer(
            name: "CurrentESCChatmail",
            managedObjectModel: model
        )
        try loadSQLiteStore(
            into: container,
            at: storeURL,
            migratesAutomatically: true
        )

        let context = container.viewContext
        let messageRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
        messageRequest.predicate = NSPredicate(format: "id == %@", "legacy-message")
        let message = try XCTUnwrap(context.fetch(messageRequest).first)
        XCTAssertNil(message.value(forKey: "listId"))
        XCTAssertNil(message.value(forKey: "replyTo"))
        XCTAssertEqual(message.value(forKey: "snippet") as? String, "legacy-body")

        let conversationRequest = NSFetchRequest<NSManagedObject>(entityName: "Conversation")
        conversationRequest.predicate = NSPredicate(format: "keyHash == %@", "legacy-key")
        let conversation = try XCTUnwrap(context.fetch(conversationRequest).first)
        XCTAssertNil(conversation.value(forKey: "listId"))
        XCTAssertEqual(conversation.value(forKey: "pinned") as? Bool, true)

        XCTAssertEqual(
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "PendingAction")),
            1
        )
        XCTAssertEqual(
            try context.count(
                for: NSFetchRequest<NSFetchRequestResult>(
                    entityName: "OutboundSendMutationRecord"
                )
            ),
            1
        )

        message.setValue("list.example.com", forKey: "listId")
        message.setValue(
            #"GitHub <reply+123456@reply.github.com>"#,
            forKey: "replyTo"
        )
        conversation.setValue("list.example.com", forKey: "listId")
        try context.save()
        context.reset()

        let savedMessage = try XCTUnwrap(context.fetch(messageRequest).first)
        let savedConversation = try XCTUnwrap(context.fetch(conversationRequest).first)
        XCTAssertEqual(savedMessage.value(forKey: "listId") as? String, "list.example.com")
        XCTAssertEqual(
            savedMessage.value(forKey: "replyTo") as? String,
            #"GitHub <reply+123456@reply.github.com>"#
        )
        XCTAssertEqual(savedConversation.value(forKey: "listId") as? String, "list.example.com")

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
