import XCTest
import CoreData
@testable import esc_chatmail

/// Pins the duplicate-Label merge pass. `Label.id` has no uniqueness
/// constraint until v4, and duplicate rows used to trap LabelPersister's
/// id-keyed dictionary construction — the merge pass repairs the store so
/// the persister's first-wins collapse stays a transient shield.
final class DuplicateLabelMergeTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var context: NSManagedObjectContext!

    private static let me = "me@example.com"

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: stack.persistentContainer)
        context = stack.viewContext
    }

    override func tearDown() {
        context = nil
        coreDataStack = nil
        stack = nil
        super.tearDown()
    }

    private func makeService() -> DataCleanupService {
        DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: InMemoryMigrationFlagStore(),
            identityAliasProvider: { _ in [Self.me] }
        )
    }

    @discardableResult
    private func makeLabel(id: String, name: String) -> Label {
        let label = context.insertTestObject(Label.self)
        label.id = id
        label.name = name
        return label
    }

    /// Two rows for one Gmail label id collapse to one, and every message
    /// association survives on the survivor (Label.messages is Nullify, so
    /// nothing cascades — but an association dropped mid-merge would silently
    /// unlabel a message).
    func testCollapsesDuplicateRowsAndKeepsMessageAssociations() async throws {
        let survivorRow = makeLabel(id: "INBOX", name: "INBOX")
        let loserRow = makeLabel(id: "INBOX", name: "INBOX")

        let conversation = ConversationBuilder().withParticipantHash("hash-a").visible().build(in: context)
        let onSurvivor = MessageBuilder().withId("msg-survivor").inConversation(conversation).build(in: context)
        let onLoser = MessageBuilder().withId("msg-loser").inConversation(conversation).build(in: context)
        let onBoth = MessageBuilder().withId("msg-both").inConversation(conversation).build(in: context)
        onSurvivor.addToLabels(survivorRow)
        onLoser.addToLabels(loserRow)
        onBoth.addToLabels(survivorRow)
        onBoth.addToLabels(loserRow)
        try context.save()

        await makeService().mergeDuplicateLabels(in: context)

        let rows = try context.fetch(Label.fetchRequest())
        XCTAssertEqual(rows.count, 1, "Duplicate rows for one label id must collapse")
        let merged = try XCTUnwrap(rows.first)
        XCTAssertEqual(
            Set((merged.messages ?? []).compactMap { $0.id }),
            ["msg-survivor", "msg-loser", "msg-both"],
            "Every message association must survive on the merged label"
        )
        XCTAssertTrue(
            (onBoth.labels ?? []).count == 1,
            "A message holding both rows must end with one label, not a duplicate pair"
        )
    }

    /// Distinct label ids are untouched, and a rerun after convergence is a
    /// no-op.
    func testDistinctLabelsUntouchedAndRerunStable() async throws {
        makeLabel(id: "INBOX", name: "INBOX")
        makeLabel(id: "INBOX", name: "INBOX")
        makeLabel(id: "SENT", name: "SENT")
        try context.save()

        let service = makeService()
        await service.mergeDuplicateLabels(in: context)
        let afterFirst = try context.fetch(Label.fetchRequest())
        XCTAssertEqual(Set(afterFirst.map { $0.id }), ["INBOX", "SENT"])
        XCTAssertEqual(afterFirst.count, 2)
        let survivorID = try XCTUnwrap(afterFirst.first { $0.id == "INBOX" }).objectID

        await service.mergeDuplicateLabels(in: context)
        let afterSecond = try context.fetch(Label.fetchRequest())
        XCTAssertEqual(afterSecond.count, 2)
        XCTAssertEqual(
            afterSecond.first { $0.id == "INBOX" }?.objectID, survivorID,
            "A rerun must not swap the survivor"
        )
    }

    /// The persister-side shield: fetchLabelsByIds must tolerate duplicate
    /// rows (it used to trap in Dictionary(uniqueKeysWithValues:)) so syncs
    /// keep working between the duplicate appearing and maintenance running.
    func testFetchLabelsByIdsToleratesDuplicateRows() throws {
        makeLabel(id: "INBOX", name: "INBOX")
        makeLabel(id: "INBOX", name: "INBOX")
        try context.save()

        let persister = MessagePersister(photoPrefetcher: { _ in })
        let byId = persister.fetchLabelsByIds(["INBOX"], in: context)
        XCTAssertEqual(byId.count, 1, "Duplicates must collapse, not trap")
        XCTAssertEqual(byId["INBOX"]?.id, "INBOX")
    }
}
