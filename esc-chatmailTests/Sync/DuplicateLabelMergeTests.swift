import XCTest
import CoreData
@testable import esc_chatmail

/// Pins the duplicate-Label merge pass. `Label.id` has no uniqueness
/// constraint until v4, and duplicate rows used to trap LabelPersister's
/// id-keyed dictionary construction — the merge pass repairs the store so
/// the persister's first-wins collapse stays a transient shield.
///
/// Every access to `context` goes through `performAndWait`, and no managed
/// object is read outside it. `mergeDuplicateLabels` runs `context.perform`
/// on this same private-queue context, and `await perform` resumes the test
/// while the block's autorelease pool is still draining on the context's
/// queue — releasing the fetched `Label`s unregisters them from the context.
/// A direct off-queue `context.fetch` in that window mutated the same object
/// table from a second thread and crashed the test runner mid
/// testDistinctLabelsUntouchedAndRerunStable (PR #233's CI run). That test,
/// unlike the first, kept no strong references to its rows, so the drain
/// actually freed them.
///
/// HONEST SCOPE: the crash needs that drain to overlap the test's fetch, so
/// no test here can reproduce it on demand; with
/// `-com.apple.CoreData.ConcurrencyDebug 1` the old off-queue shape traps at
/// its first fixture insert and this shape runs clean.
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
        let onBothID = try seedDuplicateRowsWithMessages()

        await makeService().mergeDuplicateLabels(in: context)

        let merged = try mergedLabelSnapshot(onBothID: onBothID)
        XCTAssertEqual(merged.rowCount, 1, "Duplicate rows for one label id must collapse")
        XCTAssertEqual(
            merged.messageIDs,
            ["msg-survivor", "msg-loser", "msg-both"],
            "Every message association must survive on the merged label"
        )
        XCTAssertTrue(
            merged.onBothLabelCount == 1,
            "A message holding both rows must end with one label, not a duplicate pair"
        )
    }

    /// Distinct label ids are untouched, and a rerun after convergence is a
    /// no-op.
    func testDistinctLabelsUntouchedAndRerunStable() async throws {
        try seedLabels([("INBOX", "INBOX"), ("INBOX", "INBOX"), ("SENT", "SENT")])

        let service = makeService()
        await service.mergeDuplicateLabels(in: context)
        let afterFirst = try labelRows()
        XCTAssertEqual(Set(afterFirst.map(\.id)), ["INBOX", "SENT"])
        XCTAssertEqual(afterFirst.count, 2)
        let survivorID = try XCTUnwrap(afterFirst.first { $0.id == "INBOX" }).objectID

        await service.mergeDuplicateLabels(in: context)
        let afterSecond = try labelRows()
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
        let persister = MessagePersister(photoPrefetcher: { _ in })
        try seedLabels([("INBOX", "INBOX"), ("INBOX", "INBOX")])
        let byId = context.performAndWait {
            persister.fetchLabelsByIds(["INBOX"], in: context).mapValues(\.id)
        }
        XCTAssertEqual(byId.count, 1, "Duplicates must collapse, not trap")
        XCTAssertEqual(byId["INBOX"], "INBOX")
    }

    // The on-queue helpers below are synchronous on purpose: inside an async
    // test body the same `performAndWait` closure is checked as @Sendable, and
    // capturing the (non-Sendable) test case there warns — a build error under
    // SWIFT_TREAT_WARNINGS_AS_ERRORS.

    private func seedLabels(_ rows: [(id: String, name: String)]) throws {
        try context.performAndWait {
            for row in rows {
                makeLabel(id: row.id, name: row.name)
            }
            try context.save()
        }
    }

    /// Seeds two INBOX rows with messages on the survivor, the loser, and both;
    /// returns the both-rows message's ID for the post-merge snapshot.
    private func seedDuplicateRowsWithMessages() throws -> NSManagedObjectID {
        try context.performAndWait {
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
            return onBoth.objectID
        }
    }

    private func mergedLabelSnapshot(
        onBothID: NSManagedObjectID
    ) throws -> (rowCount: Int, messageIDs: Set<String>, onBothLabelCount: Int) {
        try context.performAndWait {
            let rows = try context.fetch(Label.fetchRequest())
            let onBoth = try context.existingObject(with: onBothID) as? Message
            return (
                rowCount: rows.count,
                messageIDs: Set((rows.first?.messages ?? []).compactMap { $0.id }),
                onBothLabelCount: (onBoth?.labels ?? []).count
            )
        }
    }

    /// Value snapshot of every Label row, read on the context's queue so no
    /// managed object escapes to the test thread (see the type comment).
    private func labelRows() throws -> [(id: String, objectID: NSManagedObjectID)] {
        try context.performAndWait {
            try context.fetch(Label.fetchRequest()).map { (id: $0.id, objectID: $0.objectID) }
        }
    }
}
