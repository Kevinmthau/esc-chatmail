import CoreData
import SQLite3
import XCTest
@testable import esc_chatmail

/// Model 8 is the index half of the scalability review's step 10 plus the `bodyEvicted`
/// marker step 12 needs (`docs/scalability-review.md`, "Suggested order"). A v7 store must
/// migrate to it lightweight, keep every row, give every existing message `bodyEvicted = NO`
/// in the store itself (so a `bodyEvicted == NO` filter matches it on SQLite), and come out
/// with model 8's indexes and none of the ones it dropped.
///
/// The index assertions are the point of the `versionHashModifier` on each entity model 8
/// changes: an index-only edit leaves the entity's version hash as it was, Core Data then
/// sees nothing to migrate, and an existing store keeps its old indexes for good while a
/// new install gets the new ones.
@MainActor
final class IndexesAndBodyEvictedV8MigrationTests: XCTestCase {
    /// The fetch indexes model 8 declares, by the name Core Data gives them in SQLite.
    private static let addedIndexes: [String: Set<String>] = [
        "ZMESSAGE": ["Z_Message_byConversationAndUnreadIndex"],
        "ZCONVERSATION": ["Z_Conversation_byConversationIdIndex"],
        "ZATTACHMENT": ["Z_Attachment_byLocalURLIndex", "Z_Attachment_byPreviewURLIndex"]
    ]

    /// The fetch indexes model 7 had and model 8 drops: a byte-for-byte duplicate of a
    /// uniqueness constraint's index (`Message.byIdIndex`, `SyncCheckpoint.byKindIndex`,
    /// `AbandonedSyncMessage.byGmailMessageIdIndex`), one no fetch filters on
    /// (`Message.byGmThreadIdIndex`, `Conversation.byHiddenIndex`), and the mailbox-wide
    /// unread index the chat-open snapshot had to be spelled around
    /// (`MessagePredicates.unreadInInbox`), replaced by the per-conversation one.
    private static let droppedIndexes: [String: Set<String>] = [
        "ZMESSAGE": ["Z_Message_byIdIndex", "Z_Message_byGmThreadIdIndex", "Z_Message_byIsUnreadIndex"],
        "ZCONVERSATION": ["Z_Conversation_byHiddenIndex"],
        "ZSYNCCHECKPOINT": ["Z_SyncCheckpoint_byKindIndex"],
        "ZABANDONEDSYNCMESSAGE": ["Z_AbandonedSyncMessage_byGmailMessageIdIndex"]
    ]

    /// Indexes that must survive the migration: the ones lookups now rest on alone.
    private static let keptIndexes: [String: Set<String>] = [
        "ZMESSAGE": [
            "Z_Message_UNIQUE_id",
            "Z_Message_byInternalDateIndex",
            "Z_Message_byConversationAndDateIndex"
        ],
        "ZSYNCCHECKPOINT": ["Z_SyncCheckpoint_UNIQUE_kind"],
        "ZABANDONEDSYNCMESSAGE": ["Z_AbandonedSyncMessage_UNIQUE_gmailMessageId"]
    ]

    func testCurrentModel_declaresBodyEvictedAsANonOptionalFalseBoolean() throws {
        let currentModel = CoreDataStack.shared.persistentContainer.managedObjectModel
        let attribute = try XCTUnwrap(currentModel.entitiesByName["Message"]?.attributesByName["bodyEvicted"])
        XCTAssertEqual(attribute.attributeType, .booleanAttributeType)
        XCTAssertFalse(attribute.isOptional)
        XCTAssertEqual(attribute.defaultValue as? Bool, false)
    }

    func testV7SQLiteStore_lightweightMigratesToV8_keepsRowsMarksNothingEvictedAndSwapsIndexes() throws {
        let currentModel = CoreDataStack.shared.persistentContainer.managedObjectModel
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexesAndBodyEvictedV8Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("ESCChatmail.sqlite")
        let conversationID = UUID()

        // Both model versions name the same managed-object subclasses. Only entity-name
        // insertion and KVC are safe while the historical model is alive.
        try autoreleasepool {
            let previousModel = try loadModel(named: "ESCChatmail 7")
            XCTAssertNil(previousModel.entitiesByName["Message"]?.attributesByName["bodyEvicted"])
            let container = try open(model: previousModel, at: storeURL, migratesAutomatically: false)
            try writeV7Store(in: container.viewContext, conversationID: conversationID)
            try removeStores(from: container)
        }
        let v7Indexes = try indexNames(inStoreAt: storeURL)
        for (table, names) in Self.droppedIndexes {
            XCTAssertTrue(
                names.isSubset(of: v7Indexes[table, default: []]),
                "The v7 store must have \(table)'s dropped indexes, or the check after the migration is vacuous: \(v7Indexes[table, default: []])"
            )
        }
        for (table, names) in Self.addedIndexes {
            XCTAssertTrue(v7Indexes[table, default: []].isDisjoint(with: names), "\(table): \(v7Indexes[table, default: []])")
        }

        try autoreleasepool {
            let container = try open(model: currentModel, at: storeURL, migratesAutomatically: true)
            let context = container.viewContext

            let messages = try context.fetch(NSFetchRequest<Message>(entityName: "Message"))
            XCTAssertEqual(Set(messages.map(\.id)), ["v7-read", "v7-unread"])
            XCTAssertTrue(messages.allSatisfy { !$0.bodyEvicted })
            XCTAssertEqual(messages.first { $0.id == "v7-unread" }?.isUnread, true)
            XCTAssertEqual(messages.first { $0.id == "v7-read" }?.bodyText, "kept body")

            // Evaluated by SQLite, not in memory: a column added with no default would hold
            // NULL in the migrated rows, which reads as false here but matches no `== NO`.
            let notEvicted = NSFetchRequest<Message>(entityName: "Message")
            notEvicted.predicate = NSPredicate(format: "bodyEvicted == NO")
            XCTAssertEqual(try context.count(for: notEvicted), 2)

            let conversations = try context.fetch(NSFetchRequest<Conversation>(entityName: "Conversation"))
            XCTAssertEqual(conversations.map(\.id), [conversationID])
            XCTAssertEqual(conversations.first?.messages?.count, 2)

            let attachments = try context.fetch(NSFetchRequest<Attachment>(entityName: "Attachment"))
            XCTAssertEqual(attachments.first?.localURL, "attachments/v7/file.pdf")
            XCTAssertEqual(attachments.first?.previewURL, "previews/v7/file.jpg")

            XCTAssertEqual(try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "SyncCheckpoint")), 1)
            XCTAssertEqual(try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "AbandonedSyncMessage")), 1)

            let migrated = try XCTUnwrap(messages.first { $0.id == "v7-read" })
            migrated.bodyEvicted = true
            try context.save()
            try removeStores(from: container)
        }

        let v8Indexes = try indexNames(inStoreAt: storeURL)
        for (table, names) in Self.addedIndexes {
            XCTAssertTrue(names.isSubset(of: v8Indexes[table, default: []]), "\(table): \(v8Indexes[table, default: []])")
        }
        for (table, names) in Self.droppedIndexes {
            XCTAssertTrue(v8Indexes[table, default: []].isDisjoint(with: names), "\(table): \(v8Indexes[table, default: []])")
        }
        for (table, names) in Self.keptIndexes {
            XCTAssertTrue(names.isSubset(of: v8Indexes[table, default: []]), "\(table): \(v8Indexes[table, default: []])")
        }

        let reopened = try open(model: currentModel, at: storeURL, migratesAutomatically: false)
        let evicted = NSFetchRequest<Message>(entityName: "Message")
        evicted.predicate = NSPredicate(format: "bodyEvicted == YES")
        XCTAssertEqual(try reopened.viewContext.fetch(evicted).map(\.id), ["v7-read"])
        try removeStores(from: reopened)
    }

    /// A new install gets exactly the indexes a migrated store has, so the two cannot plan
    /// the same fetch differently.
    func testFreshV8Store_hasTheSameIndexesAsAMigratedOne() throws {
        let currentModel = CoreDataStack.shared.persistentContainer.managedObjectModel
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexesAndBodyEvictedV8Fresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("ESCChatmail.sqlite")

        let container = try open(model: currentModel, at: storeURL, migratesAutomatically: false)
        try removeStores(from: container)

        let indexes = try indexNames(inStoreAt: storeURL)
        for (table, names) in Self.addedIndexes {
            XCTAssertTrue(names.isSubset(of: indexes[table, default: []]), "\(table): \(indexes[table, default: []])")
        }
        for (table, names) in Self.droppedIndexes {
            XCTAssertTrue(indexes[table, default: []].isDisjoint(with: names), "\(table): \(indexes[table, default: []])")
        }
    }

    // MARK: - Helpers

    private func writeV7Store(in context: NSManagedObjectContext, conversationID: UUID) throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let conversation = NSEntityDescription.insertNewObject(forEntityName: "Conversation", into: context)
        conversation.setValue(conversationID, forKey: "id")
        conversation.setValue("v7-key-\(conversationID)", forKey: "keyHash")
        conversation.setValue(ConversationType.oneToOne.rawValue, forKey: "type")

        for (id, isUnread) in [("v7-read", false), ("v7-unread", true)] {
            let message = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context)
            message.setValue(id, forKey: "id")
            message.setValue("v7-thread", forKey: "gmThreadId")
            message.setValue(date, forKey: "internalDate")
            message.setValue(isUnread, forKey: "isUnread")
            message.setValue("kept body", forKey: "bodyText")
            message.setValue(conversation, forKey: "conversation")
            if id == "v7-read" {
                let attachment = NSEntityDescription.insertNewObject(forEntityName: "Attachment", into: context)
                attachment.setValue("file.pdf", forKey: "filename")
                attachment.setValue("application/pdf", forKey: "mimeType")
                attachment.setValue("attachments/v7/file.pdf", forKey: "localURL")
                attachment.setValue("previews/v7/file.jpg", forKey: "previewURL")
                attachment.setValue(message, forKey: "message")
            }
        }

        let checkpoint = NSEntityDescription.insertNewObject(forEntityName: "SyncCheckpoint", into: context)
        checkpoint.setValue(UUID(), forKey: "id")
        checkpoint.setValue("v7-kind", forKey: "kind")
        checkpoint.setValue("v7@example.com", forKey: "accountEmail")
        checkpoint.setValue(date, forKey: "createdAt")
        checkpoint.setValue(date, forKey: "updatedAt")

        let abandoned = NSEntityDescription.insertNewObject(forEntityName: "AbandonedSyncMessage", into: context)
        abandoned.setValue(UUID(), forKey: "id")
        abandoned.setValue("v7-abandoned", forKey: "gmailMessageId")
        abandoned.setValue(date, forKey: "abandonedAt")

        try context.save()
    }

    /// Every index SQLite holds in the store, by table, read from `sqlite_master` with the
    /// store detached from any coordinator.
    private func indexNames(inStoreAt storeURL: URL) throws -> [String: Set<String>] {
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(handle) }
        guard opened == SQLITE_OK, let handle else {
            throw SQLiteOpenFailure(code: opened)
        }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(
            handle,
            "SELECT tbl_name, name FROM sqlite_master WHERE type = 'index'",
            -1,
            &statement,
            nil
        )
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(prepared, SQLITE_OK, String(cString: sqlite3_errmsg(handle)))
        var indexes: [String: Set<String>] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let table = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else {
                continue
            }
            indexes[String(cString: table), default: []].insert(String(cString: name))
        }
        return indexes
    }

    private struct SQLiteOpenFailure: Error {
        let code: Int32
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
        let container = NSPersistentContainer(name: "IndexesAndBodyEvictedV8Migration", managedObjectModel: model)
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
