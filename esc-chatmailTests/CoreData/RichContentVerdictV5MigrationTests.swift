import CoreData
import XCTest
@testable import esc_chatmail

/// Pins the v4 ("ReplyRecoveryV4") → v5 ("RichContentVerdictV5") lightweight migration:
/// Message gains one optional Integer 16 column, `richContentVerdict`. A store written with
/// the bundled v4 model must open under the current model with its rows intact, and every
/// migrated message must read as an unknown verdict, so its bubble shows the loading pill
/// exactly as it did before verdicts were stored, until the backfill or a bubble load stamps
/// it.
///
/// A migration that throws is not a visible error in production: `CoreDataStack`'s recovery
/// ladder ends in a store reset. Mail re-syncs afterwards; PendingAction,
/// OutboundSendMutationRecord and ChatReplyDraft rows do not, which is why they are seeded.
@MainActor
final class RichContentVerdictV5MigrationTests: XCTestCase {

    /// Revert-check: deleting the `<attribute name="richContentVerdict" …/>` line from
    /// `ESCChatmail 5.xcdatamodel/contents`, or reverting `.xccurrentversion` to
    /// `ESCChatmail 4.xcdatamodel`, leaves the loaded model without the attribute and this
    /// fails at its first unwrap. Making the attribute required, or dropping its default,
    /// fails the shape assertions (and, with both, the migration itself).
    ///
    /// HONEST SCOPE: this migrates a store the test wrote itself with the bundled
    /// `ESCChatmail 4.mom`, on this runtime's Core Data, through its own container. It
    /// cannot prove (1) that the bundled v4 model still hashes like the v4 that shipped: a
    /// v4 edited in place passes here and leaves real stores without a migration source;
    /// (2) what another OS's Core Data leaves in the new column of migrated rows, NULL or 0,
    /// which is why the count assertions hold for either; (3) migration time or disk
    /// headroom on a real mailbox; (4) `CoreDataStack`'s own load path and recovery ladder,
    /// which this container does not go through.
    func testV4SQLiteStore_lightweightMigratesToV5_preservesRowsAndReadsUnknownVerdict() throws {
        let currentModel = CoreDataStack.shared.persistentContainer.managedObjectModel
        // Thrown, not asserted: the typed reads below trap on a model without the attribute.
        let verdictAttribute = try XCTUnwrap(
            currentModel.entitiesByName["Message"]?.attributesByName["richContentVerdict"],
            "The current model must be v5-shaped: Message.richContentVerdict is missing"
        )
        XCTAssertEqual(verdictAttribute.attributeType, .integer16AttributeType)
        XCTAssertTrue(verdictAttribute.isOptional)
        XCTAssertEqual(
            (verdictAttribute.defaultValue as? NSNumber)?.int16Value,
            0,
            "A row inserted without a verdict must hold 0, the unknown encoding"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RichContentVerdictV5Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("ESCChatmail.sqlite")
        let seed = Seed()

        // The v4 model claims the same NSManagedObject subclasses as the current one, so
        // while it is alive `+[NSManagedObject entity]` cannot pick between them. Inside
        // this pool: entity-name APIs and KVC only, and nothing created here escapes it.
        try autoreleasepool {
            let v4Model = try loadBundledModelVersion(named: "ESCChatmail 4")
            XCTAssertNil(
                v4Model.entitiesByName["Message"]?.attributesByName["richContentVerdict"],
                "The bundled v4 model must predate the verdict column or this test is vacuous"
            )
            try writeV4Store(model: v4Model, storeURL: storeURL, seed: seed)
        }
        try migrateAndVerifyStore(model: currentModel, storeURL: storeURL, seed: seed)
    }

    // MARK: - Fixture

    /// UUID-suffixed: the saves below post `NSManagedObjectContextDidSave` process-wide.
    private struct Seed {
        static let receivedThreadID = "v4-thread-received"
        static let receivedDate = Date(timeIntervalSince1970: 1_780_000_000)
        static let receivedPreview = "Stored preview"
        static let receivedBody = "<html><body><p>Stored body</p></body></html>"
        static let receivedSnippet = "Stored snippet"
        static let ownDate = Date(timeIntervalSince1970: 1_780_000_060)
        static let ownBody = "Stored reply"
        static let freshDate = Date(timeIntervalSince1970: 1_780_000_120)
        static let pendingActionDate = Date(timeIntervalSince1970: 1_780_000_180)
        static let outboundRecordDate = Date(timeIntervalSince1970: 1_780_000_240)
        static let replyEnvelope = Data("reply envelope".utf8)
        static let draftData = Data("unsent reply".utf8)
        static let draftAttachmentFilename = "draft-notes.txt"

        let conversationID = UUID()
        let pendingActionID = UUID()
        let receivedMessageID: String
        let ownMessageID: String
        let freshMessageID: String
        let outboundRecordID: String
        let conversationKeyHash: String

        var receivedBodyStorageURI: String {
            "file:///v4-store/Messages/\(receivedMessageID).html"
        }

        init() {
            let suffix = UUID().uuidString
            receivedMessageID = "v4-received-\(suffix)"
            ownMessageID = "v4-own-\(suffix)"
            freshMessageID = "v5-fresh-\(suffix)"
            outboundRecordID = "v4-outbound-\(suffix)"
            conversationKeyHash = "v4-key-\(suffix)"
        }
    }

    private func writeV4Store(
        model: NSManagedObjectModel,
        storeURL: URL,
        seed: Seed
    ) throws {
        let container = NSPersistentContainer(name: "V4ESCChatmail", managedObjectModel: model)
        try loadSQLiteStore(into: container, at: storeURL, migratesAutomatically: false)

        let context = container.viewContext

        let conversation = NSEntityDescription.insertNewObject(
            forEntityName: "Conversation",
            into: context
        )
        conversation.setValue(seed.conversationID, forKey: "id")
        conversation.setValue(seed.conversationKeyHash, forKey: "keyHash")
        conversation.setValue(ConversationType.oneToOne.rawValue, forKey: "type")
        conversation.setValue(true, forKey: "pinned")

        let received = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context)
        received.setValue(seed.receivedMessageID, forKey: "id")
        received.setValue(Seed.receivedThreadID, forKey: "gmThreadId")
        received.setValue(Seed.receivedDate, forKey: "internalDate")
        received.setValue(false, forKey: "isFromMe")
        received.setValue(Seed.receivedPreview, forKey: "chatPreviewText")
        received.setValue(Seed.receivedBody, forKey: "bodyText")
        received.setValue(Seed.receivedSnippet, forKey: "snippet")
        received.setValue(seed.receivedBodyStorageURI, forKey: "bodyStorageURI")
        received.setValue(conversation, forKey: "conversation")

        let own = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context)
        own.setValue(seed.ownMessageID, forKey: "id")
        own.setValue("v4-thread-own", forKey: "gmThreadId")
        own.setValue(Seed.ownDate, forKey: "internalDate")
        own.setValue(true, forKey: "isFromMe")
        own.setValue(Seed.ownBody, forKey: "bodyText")
        own.setValue(conversation, forKey: "conversation")

        let pendingAction = NSEntityDescription.insertNewObject(
            forEntityName: "PendingAction",
            into: context
        )
        pendingAction.setValue(seed.pendingActionID, forKey: "id")
        pendingAction.setValue("archive", forKey: "actionType")
        pendingAction.setValue(Seed.pendingActionDate, forKey: "createdAt")
        pendingAction.setValue("pending", forKey: "status")
        pendingAction.setValue(seed.receivedMessageID, forKey: "messageId")
        pendingAction.setValue(Int16(1), forKey: "retryCount")

        let mutationRecord = NSEntityDescription.insertNewObject(
            forEntityName: "OutboundSendMutationRecord",
            into: context
        )
        mutationRecord.setValue(seed.outboundRecordID, forKey: "id")
        mutationRecord.setValue(Seed.outboundRecordDate, forKey: "createdAt")
        mutationRecord.setValue(false, forKey: "newlyInsertedConversation")
        mutationRecord.setValue(false, forKey: "hidden")
        mutationRecord.setValue(seed.conversationID, forKey: "conversationId")
        mutationRecord.setValue(Seed.replyEnvelope, forKey: "replyEnvelopeData")

        let draft = NSEntityDescription.insertNewObject(
            forEntityName: "ChatReplyDraft",
            into: context
        )
        draft.setValue(seed.conversationID, forKey: "conversationId")
        draft.setValue(Seed.draftData, forKey: "data")

        let draftAttachment = NSEntityDescription.insertNewObject(
            forEntityName: "Attachment",
            into: context
        )
        draftAttachment.setValue(Seed.draftAttachmentFilename, forKey: "filename")
        draftAttachment.setValue("text/plain", forKey: "mimeType")
        draftAttachment.setValue(draft, forKey: "replyDraft")

        try context.save()
        try removeStores(from: container)
    }

    // MARK: - Verification

    private func migrateAndVerifyStore(
        model: NSManagedObjectModel,
        storeURL: URL,
        seed: Seed
    ) throws {
        let container = NSPersistentContainer(name: "V5ESCChatmail", managedObjectModel: model)
        try loadSQLiteStore(into: container, at: storeURL, migratesAutomatically: true)

        let context = container.viewContext

        let received = try fetchMessage(id: seed.receivedMessageID, in: context)
        XCTAssertFalse(received.isFromMe)
        XCTAssertEqual(received.gmThreadId, Seed.receivedThreadID)
        XCTAssertEqual(received.internalDate, Seed.receivedDate)
        XCTAssertEqual(received.chatPreviewText, Seed.receivedPreview)
        XCTAssertEqual(received.bodyText, Seed.receivedBody)
        XCTAssertEqual(received.snippet, Seed.receivedSnippet)
        XCTAssertEqual(received.bodyStorageURI, seed.receivedBodyStorageURI)
        XCTAssertEqual(received.conversation?.id, seed.conversationID)
        XCTAssertEqual(received.conversation?.pinned, true, "Local-only chat state must survive")

        let own = try fetchMessage(id: seed.ownMessageID, in: context)
        XCTAssertTrue(own.isFromMe)
        XCTAssertEqual(own.internalDate, Seed.ownDate)
        XCTAssertEqual(own.bodyText, Seed.ownBody)
        XCTAssertEqual(own.conversation?.id, seed.conversationID)

        try assertNonResyncableRowsIntact(in: context, seed: seed)

        // Migrated rows carry no verdict: the scalar reads 0 whether the column holds NULL
        // or 0, and 0 decodes as unknown under every epoch.
        for message in [received, own] {
            XCTAssertEqual(message.richContentVerdict, 0)
            XCTAssertEqual(message.storedRichContentVerdict, .unknown)
        }

        // The only filter that finds every unstamped row. Which disjunct the migrated rows
        // sit under is Core Data's choice, not the model's: a standalone macOS 27 probe saw
        // the default backfilled (`== 0` matched both, `== nil` neither), but a runtime that
        // leaves NULL is matched by `== nil` alone. So the split is recorded in the activity
        // name rather than pinned, and production never filters on the attribute without
        // the nil disjunct.
        let unstamped = NSPredicate(format: "richContentVerdict == nil OR richContentVerdict == 0")
        let holdsNull = NSPredicate(format: "richContentVerdict == nil")
        let holdsZero = NSPredicate(format: "richContentVerdict == 0")
        XCTAssertEqual(
            try messageCount(matching: unstamped, in: context),
            2,
            "Both migrated rows must be reachable as unstamped"
        )
        let nullMatches = try messageCount(matching: holdsNull, in: context)
        let zeroMatches = try messageCount(matching: holdsZero, in: context)
        XCTContext.runActivity(
            named: "Migrated rows matched by `== nil`: \(nullMatches), by `== 0`: \(zeroMatches)"
        ) { _ in
            XCTAssertEqual(
                nullMatches + zeroMatches,
                2,
                "Each migrated row holds exactly one of NULL and 0"
            )
        }

        // The column is writable after migration, and a row inserted under v5 takes the
        // model default.
        received.storedRichContentVerdict = .rich
        let fresh = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context)
        fresh.setValue(seed.freshMessageID, forKey: "id")
        fresh.setValue("v5-thread-fresh", forKey: "gmThreadId")
        fresh.setValue(Seed.freshDate, forKey: "internalDate")
        try context.save()
        context.reset()

        let stamped = try fetchMessage(id: seed.receivedMessageID, in: context)
        XCTAssertEqual(stamped.storedRichContentVerdict, .rich)
        XCTAssertEqual(stamped.richContentVerdict, RichContentVerdict.rich.storedValue())
        XCTAssertEqual(stamped.chatPreviewText, Seed.receivedPreview)
        XCTAssertEqual(
            try fetchMessage(id: seed.ownMessageID, in: context).storedRichContentVerdict,
            .unknown,
            "Stamping one row must not touch its neighbour"
        )
        XCTAssertEqual(
            try fetchMessage(id: seed.freshMessageID, in: context).storedRichContentVerdict,
            .unknown
        )
        XCTAssertEqual(
            try messageCount(matching: unstamped, in: context),
            2,
            "The stamped row leaves the unstamped set; the own row and the new row remain"
        )
        // Deterministic half of the split: whatever migration left behind, `== 0` is live
        // in every store because new rows are inserted with the default.
        let freshRowHoldsZero = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "id == %@", seed.freshMessageID),
            holdsZero
        ])
        XCTAssertEqual(try messageCount(matching: freshRowHoldsZero, in: context), 1)

        try assertNonResyncableRowsIntact(in: context, seed: seed)
        XCTAssertEqual(
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Message")),
            3
        )

        try removeStores(from: container)
    }

    /// The rows a store reset would lose for good; exactly one of each was seeded.
    private func assertNonResyncableRowsIntact(
        in context: NSManagedObjectContext,
        seed: Seed
    ) throws {
        let pendingActions = try context.fetch(
            NSFetchRequest<PendingAction>(entityName: "PendingAction")
        )
        XCTAssertEqual(pendingActions.count, 1)
        let pendingAction = try XCTUnwrap(pendingActions.first)
        XCTAssertEqual(pendingAction.id, seed.pendingActionID)
        XCTAssertEqual(pendingAction.actionType, "archive")
        XCTAssertEqual(pendingAction.status, "pending")
        XCTAssertEqual(pendingAction.messageId, seed.receivedMessageID)
        XCTAssertEqual(pendingAction.retryCount, 1)
        XCTAssertEqual(pendingAction.createdAt, Seed.pendingActionDate)

        let mutationRecords = try context.fetch(
            NSFetchRequest<OutboundSendMutationRecord>(entityName: "OutboundSendMutationRecord")
        )
        XCTAssertEqual(mutationRecords.count, 1)
        let mutationRecord = try XCTUnwrap(mutationRecords.first)
        XCTAssertEqual(mutationRecord.id, seed.outboundRecordID)
        XCTAssertEqual(mutationRecord.createdAt, Seed.outboundRecordDate)
        XCTAssertEqual(mutationRecord.conversationId, seed.conversationID)
        XCTAssertEqual(mutationRecord.replyEnvelopeData, Seed.replyEnvelope)

        let drafts = try context.fetch(
            NSFetchRequest<ChatReplyDraft>(entityName: "ChatReplyDraft")
        )
        XCTAssertEqual(drafts.count, 1)
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.conversationId, seed.conversationID)
        XCTAssertEqual(draft.data, Seed.draftData)
        XCTAssertEqual(
            draft.attachments?.map(\.filename),
            [Seed.draftAttachmentFilename],
            "A draft's attachments are as unrecoverable as its text"
        )
    }

    // MARK: - Helpers

    private func fetchMessage(
        id: String,
        in context: NSManagedObjectContext
    ) throws -> Message {
        let request = NSFetchRequest<Message>(entityName: "Message")
        request.predicate = NSPredicate(format: "id == %@", id)
        return try XCTUnwrap(context.fetch(request).first, "Message \(id) is missing")
    }

    private func messageCount(
        matching predicate: NSPredicate,
        in context: NSManagedObjectContext
    ) throws -> Int {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
        request.predicate = predicate
        return try context.count(for: request)
    }

    private func loadBundledModelVersion(named name: String) throws -> NSManagedObjectModel {
        let candidateBundles = [Bundle(for: CoreDataStack.self), Bundle.main]
        let modelDirectory = try XCTUnwrap(
            candidateBundles.lazy.compactMap {
                $0.url(forResource: "ESCChatmail", withExtension: "momd")
            }.first,
            "The versioned ESCChatmail.momd must be compiled into the host app"
        )
        let modelURL = modelDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("mom")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: modelURL.path),
            "\(name).mom missing from the bundle — upgrading stores would have no migration source"
        )
        return try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
    }

    /// The production store options (`CoreDataStack.persistentContainer`): automatic,
    /// inferred migration of a history-tracked SQLite store. The v4 writer tracks history
    /// too, as every shipped store does, so the migration has the history tables to carry.
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
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        if let loadError {
            throw loadError
        }
    }

    private func removeStores(from container: NSPersistentContainer) throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
}
