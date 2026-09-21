import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class ReplyRecoveryV4MigrationTests: XCTestCase {
    func testV3StoreMigratesWithoutLosingAttachmentOrPendingSend() throws {
        let bundle = Bundle(for: CoreDataStack.self)
        let modelURL = try XCTUnwrap(bundle.url(forResource: "ESCChatmail", withExtension: "momd")
                                    ?? Bundle.main.url(forResource: "ESCChatmail", withExtension: "momd"))
        let previousModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL.appendingPathComponent("ESCChatmail 3.mom")))
        let currentModel = CoreDataStack.shared.persistentContainer.managedObjectModel
        XCTAssertNil(previousModel.entitiesByName["ChatReplyDraft"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.sqlite")

        try autoreleasepool {
            let container = try open(model: previousModel, url: url)
            let context = container.viewContext
            let attachment = NSEntityDescription.insertNewObject(forEntityName: "Attachment", into: context)
            attachment.setValue("legacy-file", forKey: "id")
            attachment.setValue("notes.txt", forKey: "filename")
            attachment.setValue("text/plain", forKey: "mimeType")
            let record = NSEntityDescription.insertNewObject(forEntityName: "OutboundSendMutationRecord", into: context)
            record.setValue("legacy-send", forKey: "id")
            record.setValue(Date(), forKey: "createdAt")
            record.setValue(OutboundSendRemoteState.ambiguousMessageID, forKey: "remoteCommittedMessageId")
            try context.save()
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }
        let migrated = try open(model: currentModel, url: url)
        let record = try XCTUnwrap(migrated.viewContext.fetch(OutboundSendMutationRecord.fetchRequest()).first)
        XCTAssertEqual(record.id, "legacy-send")
        XCTAssertEqual(record.remoteCommittedMessageId, OutboundSendRemoteState.ambiguousMessageID)
        XCTAssertNil(record.replyEnvelopeData)
        XCTAssertNil(record.failureReason)
        let attachment = try XCTUnwrap(migrated.viewContext.fetch(Attachment.fetchRequest()).first)
        XCTAssertEqual(attachment.filename, "notes.txt")
        XCTAssertNil(attachment.replyDraft)
        let draft = ChatReplyDraft(context: migrated.viewContext)
        draft.conversationId = UUID()
        draft.data = Data("draft".utf8)
        attachment.replyDraft = draft
        try migrated.viewContext.save()
        migrated.viewContext.reset()
        XCTAssertNotNil(try migrated.viewContext.fetch(Attachment.fetchRequest()).first?.replyDraft)
        for store in migrated.persistentStoreCoordinator.persistentStores {
            try migrated.persistentStoreCoordinator.remove(store)
        }
    }

    private func open(model: NSManagedObjectModel, url: URL) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "ReplyMigration", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        var failure: Error?
        container.loadPersistentStores { _, error in failure = error }
        if let failure { throw failure }
        return container
    }
}
