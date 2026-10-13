import CoreData
import XCTest
@testable import esc_chatmail

/// A v5 store must migrate without resetting the local draft and send-recovery rows.
/// The new recipient headers start nil for legacy mail and remain writable after migration.
@MainActor
final class RecipientHeadersV6MigrationTests: XCTestCase {
    func testV5SQLiteStore_lightweightMigratesToV6_preservesLocalRowsAndRecipientHeaders() throws {
        let currentModel = CoreDataStack.shared.persistentContainer.managedObjectModel
        for key in ["rawToHeader", "rawCcHeader"] {
            let attribute = try XCTUnwrap(currentModel.entitiesByName["Message"]?.attributesByName[key])
            XCTAssertEqual(attribute.attributeType, .stringAttributeType)
            XCTAssertTrue(attribute.isOptional)
            XCTAssertNil(attribute.defaultValue)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecipientHeadersV6Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("ESCChatmail.sqlite")
        let seed = Seed()

        // Both model versions name the same managed-object subclasses. Only entity-name
        // insertion and KVC are safe while the historical model is alive.
        try autoreleasepool {
            let previousModel = try loadV5Model()
            XCTAssertNil(previousModel.entitiesByName["Message"]?.attributesByName["rawToHeader"])
            XCTAssertNil(previousModel.entitiesByName["Message"]?.attributesByName["rawCcHeader"])
            try writeV5Store(model: previousModel, at: storeURL, seed: seed)
        }

        try autoreleasepool {
            let container = try open(model: currentModel, at: storeURL, migratesAutomatically: true)
            let context = container.viewContext
            let legacy = try fetchMessage(id: seed.legacyMessageID, in: context)
            XCTAssertNil(legacy.rawToHeader)
            XCTAssertNil(legacy.rawCcHeader)
            XCTAssertEqual(legacy.bodyText, Seed.body)
            XCTAssertEqual(legacy.richContentVerdict, Seed.verdict)
            XCTAssertEqual(legacy.conversation?.id, seed.conversationID)
            XCTAssertEqual(legacy.conversation?.pinned, true)
            try assertLocalRowsIntact(in: context, seed: seed)

            legacy.rawToHeader = Seed.toHeader
            legacy.rawCcHeader = Seed.ccHeader

            let fresh = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context)
            fresh.setValue(seed.freshMessageID, forKey: "id")
            fresh.setValue("v6-thread", forKey: "gmThreadId")
            fresh.setValue(Seed.date, forKey: "internalDate")
            try context.save()
            try removeStores(from: container)
        }

        // Reopening the SQLite file verifies persistence, including nil defaults for a
        // newly inserted message, rather than reading the objects just written in memory.
        let reopened = try open(model: currentModel, at: storeURL, migratesAutomatically: false)
        let legacy = try fetchMessage(id: seed.legacyMessageID, in: reopened.viewContext)
        XCTAssertEqual(legacy.rawToHeader, Seed.toHeader)
        XCTAssertEqual(legacy.rawCcHeader, Seed.ccHeader)
        XCTAssertEqual(legacy.bodyText, Seed.body)
        XCTAssertEqual(legacy.richContentVerdict, Seed.verdict)
        let fresh = try fetchMessage(id: seed.freshMessageID, in: reopened.viewContext)
        XCTAssertNil(fresh.rawToHeader)
        XCTAssertNil(fresh.rawCcHeader)
        XCTAssertEqual(
            try reopened.viewContext.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Message")),
            2
        )
        try assertLocalRowsIntact(in: reopened.viewContext, seed: seed)
        try removeStores(from: reopened)
    }

    private struct Seed {
        static let date = Date(timeIntervalSince1970: 1_780_000_000)
        static let body = "Stored message body"
        static let verdict: Int16 = 1
        static let toHeader = "\"Doe, Jane\" <jane@example.com>, Team: alex@example.com;"
        static let ccHeader = "=?UTF-8?B?Sm9zw6k=?= <jose@example.com>"
        static let draftData = Data("unsent reply".utf8)
        static let replyEnvelope = Data("pending reply envelope".utf8)
        static let draftFilename = "unsent-notes.txt"

        let conversationID = UUID()
        let pendingActionID = UUID()
        let legacyMessageID = "v5-message-\(UUID().uuidString)"
        let freshMessageID = "v6-message-\(UUID().uuidString)"
        let outboundRecordID = "v5-outbound-\(UUID().uuidString)"
    }

    private func writeV5Store(model: NSManagedObjectModel, at storeURL: URL, seed: Seed) throws {
        let container = try open(model: model, at: storeURL, migratesAutomatically: false)
        let context = container.viewContext

        let conversation = NSEntityDescription.insertNewObject(forEntityName: "Conversation", into: context)
        conversation.setValue(seed.conversationID, forKey: "id")
        conversation.setValue("v5-key-\(seed.conversationID)", forKey: "keyHash")
        conversation.setValue(ConversationType.oneToOne.rawValue, forKey: "type")
        conversation.setValue(true, forKey: "pinned")

        let message = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context)
        message.setValue(seed.legacyMessageID, forKey: "id")
        message.setValue("v5-thread", forKey: "gmThreadId")
        message.setValue(Seed.date, forKey: "internalDate")
        message.setValue(Seed.body, forKey: "bodyText")
        message.setValue(Seed.verdict, forKey: "richContentVerdict")
        message.setValue(conversation, forKey: "conversation")

        let pending = NSEntityDescription.insertNewObject(forEntityName: "PendingAction", into: context)
        pending.setValue(seed.pendingActionID, forKey: "id")
        pending.setValue("archive", forKey: "actionType")
        pending.setValue(Seed.date, forKey: "createdAt")
        pending.setValue(seed.legacyMessageID, forKey: "messageId")
        pending.setValue(Int16(2), forKey: "retryCount")

        let outbound = NSEntityDescription.insertNewObject(forEntityName: "OutboundSendMutationRecord", into: context)
        outbound.setValue(seed.outboundRecordID, forKey: "id")
        outbound.setValue(Seed.date, forKey: "createdAt")
        outbound.setValue(seed.conversationID, forKey: "conversationId")
        outbound.setValue(Seed.replyEnvelope, forKey: "replyEnvelopeData")
        outbound.setValue(OutboundSendRemoteState.ambiguousMessageID, forKey: "remoteCommittedMessageId")

        let draft = NSEntityDescription.insertNewObject(forEntityName: "ChatReplyDraft", into: context)
        draft.setValue(seed.conversationID, forKey: "conversationId")
        draft.setValue(Seed.draftData, forKey: "data")

        let attachment = NSEntityDescription.insertNewObject(forEntityName: "Attachment", into: context)
        attachment.setValue(Seed.draftFilename, forKey: "filename")
        attachment.setValue("text/plain", forKey: "mimeType")
        attachment.setValue(draft, forKey: "replyDraft")

        try context.save()
        try removeStores(from: container)
    }

    private func assertLocalRowsIntact(in context: NSManagedObjectContext, seed: Seed) throws {
        let actions = try context.fetch(NSFetchRequest<PendingAction>(entityName: "PendingAction"))
        XCTAssertEqual(actions.count, 1)
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.id, seed.pendingActionID)
        XCTAssertEqual(action.actionType, "archive")
        XCTAssertEqual(action.createdAt, Seed.date)
        XCTAssertEqual(action.messageId, seed.legacyMessageID)
        XCTAssertEqual(action.retryCount, 2)
        XCTAssertEqual(action.status, "pending")

        let records = try context.fetch(NSFetchRequest<OutboundSendMutationRecord>(entityName: "OutboundSendMutationRecord"))
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.id, seed.outboundRecordID)
        XCTAssertEqual(record.createdAt, Seed.date)
        XCTAssertEqual(record.conversationId, seed.conversationID)
        XCTAssertEqual(record.replyEnvelopeData, Seed.replyEnvelope)
        XCTAssertEqual(record.remoteCommittedMessageId, OutboundSendRemoteState.ambiguousMessageID)

        let drafts = try context.fetch(NSFetchRequest<ChatReplyDraft>(entityName: "ChatReplyDraft"))
        XCTAssertEqual(drafts.count, 1)
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.conversationId, seed.conversationID)
        XCTAssertEqual(draft.data, Seed.draftData)
        XCTAssertEqual(draft.attachments?.map(\.filename), [Seed.draftFilename])
    }

    private func fetchMessage(id: String, in context: NSManagedObjectContext) throws -> Message {
        let request = NSFetchRequest<Message>(entityName: "Message")
        request.predicate = NSPredicate(format: "id == %@", id)
        return try XCTUnwrap(context.fetch(request).first)
    }

    private func loadV5Model() throws -> NSManagedObjectModel {
        let bundles = [Bundle(for: CoreDataStack.self), Bundle.main]
        let modelDirectory = try XCTUnwrap(bundles.lazy.compactMap {
            $0.url(forResource: "ESCChatmail", withExtension: "momd")
        }.first)
        return try XCTUnwrap(NSManagedObjectModel(
            contentsOf: modelDirectory.appendingPathComponent("ESCChatmail 5.mom")
        ))
    }

    private func open(
        model: NSManagedObjectModel,
        at storeURL: URL,
        migratesAutomatically: Bool
    ) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "RecipientHeadersMigration", managedObjectModel: model)
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
