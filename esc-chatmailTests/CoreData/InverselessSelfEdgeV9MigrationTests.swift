import CoreData
import SQLite3
import XCTest
@testable import esc_chatmail

/// Model 9 drops the inverse `Person.messageParticipations` (architecture
/// review 2026-11, data-model#3, sync-persist-path#1, coredata-stack#4 and the
/// model-9 half of gap-message-shape-extremes#5): for the user's own Person it
/// was every message of the mailbox, and setting a participant's person read
/// all of it into the writing context. It also adds `Message.lastViewedAt` for
/// the attachments-disk line's eviction pass. A v8 store must migrate to it
/// lightweight and keep every row: each participant still names its person,
/// several participants still name one person, and every migrated message
/// reads `lastViewedAt` nil, with the store's indexes unchanged.
///
/// `Label.messages` keeps its inverse, on purpose: Core Data stores a to-many
/// relationship with no inverse as a one-to-many (the model compiler says so:
/// "no object can be in multiple destinations"), so `Message.labels` without it
/// would let a label belong to one message only, and a v8 store migrated to a
/// model 9 without it raised an uncaught `NSInternalInconsistencyException`
/// ("Unsupported relationship migration: A to-one's inverse to-many source
/// must be a to-many"), a launch crash (throwaway probe, iOS 27.0 simulator,
/// 2026-11-28). The label hub needs the denormalized flags instead, which
/// this model does not carry.
///
/// Model 9's migration from 8, measured on the S2 scale store: an
/// `ALTER TABLE ZMESSAGE ADD COLUMN` and a copy of `ZPERSON` alone, about
/// 0.23 s; `ZMESSAGEPARTICIPANT` is not rebuilt.
@MainActor
final class InverselessSelfEdgeV9MigrationTests: XCTestCase {
    func testCurrentModel_dropsOnlyThePersonInverse_andDeclaresLastViewedAt() throws {
        let model = CoreDataStack.shared.persistentContainer.managedObjectModel
        XCTAssertNil(model.entitiesByName["Person"]?.relationshipsByName["messageParticipations"])
        let person = try XCTUnwrap(model.entitiesByName["MessageParticipant"]?.relationshipsByName["person"])
        XCTAssertNil(person.inverseRelationship)
        XCTAssertFalse(person.isToMany)
        // Kept: without it a label could belong to one message only (see the
        // type's comment), which the migration below would show, one label
        // being on two messages there.
        XCTAssertNotNil(model.entitiesByName["Message"]?.relationshipsByName["labels"]?.inverseRelationship)
        let lastViewedAt = try XCTUnwrap(model.entitiesByName["Message"]?.attributesByName["lastViewedAt"])
        XCTAssertEqual(lastViewedAt.attributeType, .dateAttributeType)
        XCTAssertTrue(lastViewedAt.isOptional)
        XCTAssertNil(lastViewedAt.defaultValue)
    }

    func testV8SQLiteStore_lightweightMigratesToV9_keepsEveryParticipantsPersonAndEveryLabel() throws {
        let currentModel = CoreDataStack.shared.persistentContainer.managedObjectModel
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InverselessSelfEdgeV9Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("ESCChatmail.sqlite")

        // Both model versions name the same managed-object subclasses. Only
        // entity-name insertion and KVC are safe while the historical model
        // is alive.
        try autoreleasepool {
            let previousModel = try loadModel(named: "ESCChatmail 8")
            XCTAssertNotNil(previousModel.entitiesByName["Person"]?.relationshipsByName["messageParticipations"])
            let container = try open(model: previousModel, at: storeURL, migratesAutomatically: false)
            try writeV8Store(in: container.viewContext)
            try removeStores(from: container)
        }
        let v8Indexes = try indexNames(inStoreAt: storeURL)

        try autoreleasepool {
            let container = try open(model: currentModel, at: storeURL, migratesAutomatically: true)
            let context = container.viewContext

            let messages = try context.fetch(NSFetchRequest<Message>(entityName: "Message"))
            XCTAssertEqual(Set(messages.map(\.id)), ["v8-first", "v8-second"])
            for message in messages {
                XCTAssertEqual(Set((message.labels ?? []).map(\.id)), ["INBOX", "UNREAD"], message.id)
                let participants = Set((message.participants ?? []).map { "\($0.kind):\($0.person?.email ?? "nil")" })
                XCTAssertEqual(participants, ["from:alice@example.com", "to:me@example.com"], message.id)
            }

            // Evaluated by SQLite: every migrated row holds no date.
            let neverViewed = NSFetchRequest<Message>(entityName: "Message")
            neverViewed.predicate = NSPredicate(format: "lastViewedAt == nil")
            XCTAssertEqual(try context.count(for: neverViewed), 2)

            // The user's Person is still named by both messages' rows, found
            // by a fetch now that the inverse is gone.
            let mine = NSFetchRequest<MessageParticipant>(entityName: "MessageParticipant")
            mine.predicate = NSPredicate(format: "person.email == %@", "me@example.com")
            XCTAssertEqual(try context.count(for: mine), 2)
            let inbox = NSFetchRequest<Label>(entityName: "Label")
            inbox.predicate = NSPredicate(format: "id == %@", "INBOX")
            XCTAssertEqual(try XCTUnwrap(try context.fetch(inbox).first).messages?.count, 2)

            let viewed = try XCTUnwrap(messages.first { $0.id == "v8-first" })
            viewed.lastViewedAt = Date(timeIntervalSince1970: 1_800_000_000)
            try context.save()
            try removeStores(from: container)
        }

        XCTAssertEqual(try indexNames(inStoreAt: storeURL), v8Indexes, "Model 9 changes no index")

        let reopened = try open(model: currentModel, at: storeURL, migratesAutomatically: false)
        let viewed = NSFetchRequest<Message>(entityName: "Message")
        viewed.predicate = NSPredicate(format: "lastViewedAt != nil")
        XCTAssertEqual(try reopened.viewContext.fetch(viewed).map(\.id), ["v8-first"])
        try removeStores(from: reopened)
    }

    // MARK: - Helpers

    /// Two messages of one conversation, from Alice to the user, each labeled
    /// INBOX and UNREAD: one Person and one Label on two messages each.
    private func writeV8Store(in context: NSManagedObjectContext) throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let conversation = NSEntityDescription.insertNewObject(forEntityName: "Conversation", into: context)
        conversation.setValue(UUID(), forKey: "id")
        conversation.setValue("v8-key", forKey: "keyHash")
        conversation.setValue(ConversationType.oneToOne.rawValue, forKey: "type")

        var labels: [NSManagedObject] = []
        for id in ["INBOX", "UNREAD"] {
            let label = NSEntityDescription.insertNewObject(forEntityName: "Label", into: context)
            label.setValue(id, forKey: "id")
            label.setValue(id, forKey: "name")
            labels.append(label)
        }
        var persons: [String: NSManagedObject] = [:]
        for email in ["alice@example.com", "me@example.com"] {
            let person = NSEntityDescription.insertNewObject(forEntityName: "Person", into: context)
            person.setValue(UUID(), forKey: "id")
            person.setValue(email, forKey: "email")
            persons[email] = person
        }

        for id in ["v8-first", "v8-second"] {
            let message = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context)
            message.setValue(id, forKey: "id")
            message.setValue("v8-thread", forKey: "gmThreadId")
            message.setValue(date, forKey: "internalDate")
            message.setValue(true, forKey: "isUnread")
            message.setValue(conversation, forKey: "conversation")
            message.setValue(Set(labels), forKey: "labels")
            for (kind, email) in [("from", "alice@example.com"), ("to", "me@example.com")] {
                let participant = NSEntityDescription.insertNewObject(forEntityName: "MessageParticipant", into: context)
                participant.setValue(UUID(), forKey: "id")
                participant.setValue(kind, forKey: "kind")
                participant.setValue(persons[email], forKey: "person")
                participant.setValue(message, forKey: "message")
            }
        }
        try context.save()
    }

    /// Every index SQLite holds in the store, by table, read from
    /// `sqlite_master` with the store detached from any coordinator.
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
        let container = NSPersistentContainer(name: "InverselessSelfEdgeV9Migration", managedObjectModel: model)
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
