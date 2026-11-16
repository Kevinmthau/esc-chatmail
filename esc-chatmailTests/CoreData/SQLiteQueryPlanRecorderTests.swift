import XCTest
import CoreData
@testable import esc_chatmail

/// Pins the recorder the scale harness reads its query plans with
/// (`ScaleQueryPlanTests`, which runs only under `--performance`). This suite
/// is in the default plan because the recorder leans on two things that are
/// not public API, Core Data's SQL debug switch and what level 4 writes to
/// standard error: if a new SDK changes either, the failure has to show up in
/// an ordinary run, not months later in an opt-in one. CI runs it on another
/// Xcode than this Mac's.
final class SQLiteQueryPlanRecorderTests: XCTestCase {
    private typealias Plan = SQLiteQueryPlanRecorder.Plan

    // MARK: - Parsing

    /// What Core Data wrote for one fetch at level 4 (iOS 27.0 simulator),
    /// cut down: the statement, its bindings, the statement again with its
    /// plan rows, then annotations.
    private static let recordedLog = """
    CoreData: sql: SELECT 0, t0.Z_PK FROM ZMESSAGE t0 JOIN ZCONVERSATION t1 ON t0.ZCONVERSATION = t1.Z_PK WHERE  t1.ZID = ? ORDER BY t0.ZINTERNALDATE LIMIT 20
    CoreData: details: SQLite bind[0] = 7BD415DB-75CA-45DF-8EB1-B21047791D83
    CoreData: details: SQLite: SELECT 0, t0.Z_PK FROM ZMESSAGE t0 JOIN ZCONVERSATION t1 ON t0.ZCONVERSATION = t1.Z_PK WHERE  t1.ZID = ? ORDER BY t0.ZINTERNALDATE LIMIT 20
         6 0 212 SCAN t0 USING INDEX Z_Message_byInternalDateIndex
         50 0 45 SEARCH t1 USING INTEGER PRIMARY KEY (rowid=?)
    CoreData: annotation: sql connection fetch time: 0.0017s
    CoreData: annotation: total fetch execution time: 0.0065s for 20 rows.
    CoreData: details: SQLite: BEGIN EXCLUSIVE
    CoreData: sql: COMMIT
    CoreData: details: SQLite: SELECT COUNT( DISTINCT t0.Z_PK) FROM ZMESSAGE t0 WHERE  t0.ZISUNREAD = ?
         4 0 0 SEARCH t0 USING COVERING INDEX Z_Message_byIsUnreadIndex (ZISUNREAD=?)
    """

    /// Revert-check: in `SQLiteQueryPlanRecorder.parse`, taking the statement
    /// from the `CoreData: sql:` line loses the first plan (the bindings come
    /// between that line and the rows).
    func testParse_readsEachStatementWithTheRowsRightAfterIt() {
        let plans = SQLiteQueryPlanRecorder.parse(Self.recordedLog)

        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans.first?.steps, [
            "SCAN t0 USING INDEX Z_Message_byInternalDateIndex",
            "SEARCH t1 USING INTEGER PRIMARY KEY (rowid=?)"
        ])
        XCTAssertEqual(plans.first?.sql.hasPrefix("SELECT 0, t0.Z_PK FROM ZMESSAGE t0"), true)
        XCTAssertEqual(plans.last?.steps, [
            "SEARCH t0 USING COVERING INDEX Z_Message_byIsUnreadIndex (ZISUNREAD=?)"
        ])
    }

    /// A statement with no rows after it (`BEGIN EXCLUSIVE`) is not a plan,
    /// and rows belong to a statement only when they come right after it:
    /// numbers further down the log are something else's.
    /// Revert-check: the `!steps.isEmpty` condition in `parse`'s `finish`
    /// (the first two assertions), and the `finish()` on a line that is
    /// neither a statement nor a row (the last one).
    func testParse_statementWithoutPlanRowsRightAfterIt_isNotAPlan() {
        let plans = SQLiteQueryPlanRecorder.parse(Self.recordedLog)

        XCTAssertFalse(plans.contains { $0.sql.contains("BEGIN") })
        XCTAssertEqual(SQLiteQueryPlanRecorder.parse("CoreData: details: SQLite: BEGIN EXCLUSIVE"), [])
        XCTAssertEqual(SQLiteQueryPlanRecorder.parse(""), [])
        XCTAssertEqual(
            SQLiteQueryPlanRecorder.parse("""
            CoreData: details: SQLite: BEGIN EXCLUSIVE
            CoreData: annotation: sql connection fetch time: 0.0017s
                 3 0 0 SCAN t0
            """),
            []
        )
    }

    // MARK: - Reading a plan

    /// Revert-check: `Plan.scans(of:)` matching any step that names the alias
    /// counts the `SEARCH t1` row as a scan of ZCONVERSATION; matching `SCAN`
    /// alone, with no alias, counts the scan of ZMESSAGE against ZCONVERSATION.
    func testPlan_scans_areTheRowsThatWalkThatTableFromOneEnd() throws {
        let plan = try XCTUnwrap(SQLiteQueryPlanRecorder.parse(Self.recordedLog).first)

        XCTAssertEqual(plan.aliases(of: "ZMESSAGE"), ["t0"])
        XCTAssertEqual(plan.aliases(of: "ZCONVERSATION"), ["t1"])
        XCTAssertEqual(plan.scans(of: "ZMESSAGE"), ["SCAN t0 USING INDEX Z_Message_byInternalDateIndex"])
        XCTAssertEqual(plan.scans(of: "ZCONVERSATION"), [])
        XCTAssertTrue(plan.reads("ZMESSAGE"))
        XCTAssertFalse(plan.reads("ZLABEL"))
        XCTAssertEqual(plan.scans(of: "ZLABEL"), [])
    }

    /// A bare `SCAN t0`, with no index, is a scan too, and `t1` is not `t10`.
    /// Revert-check: the `step == "SCAN \(alias)"` half of `Plan.scans(of:)`,
    /// and the space after the alias in its other half.
    func testPlan_scans_bareScanCounts_andAnAliasIsNotAPrefixOfAnother() {
        let plan = Plan(
            sql: "SELECT COUNT(*) FROM ZMESSAGE t1 JOIN ZLABEL t10 ON t1.Z_PK = t10.Z_PK",
            steps: ["SCAN t1", "SCAN t10 USING INDEX Z_Label_byIdIndex"]
        )

        XCTAssertEqual(plan.scans(of: "ZMESSAGE"), ["SCAN t1"])
        XCTAssertEqual(plan.scans(of: "ZLABEL"), ["SCAN t10 USING INDEX Z_Label_byIdIndex"])
    }

    /// Revert-check: `Plan.indexes(on:)` returning the index of any step
    /// gives ZCONVERSATION the message index.
    func testPlan_indexes_areTheIndexesUsedOnThatTable() throws {
        let plans = SQLiteQueryPlanRecorder.parse(Self.recordedLog)
        let first = try XCTUnwrap(plans.first)
        let last = try XCTUnwrap(plans.last)

        XCTAssertEqual(first.indexes(on: "ZMESSAGE"), ["Z_Message_byInternalDateIndex"])
        XCTAssertEqual(first.indexes(on: "ZCONVERSATION"), [])
        XCTAssertEqual(last.indexes(on: "ZMESSAGE"), ["Z_Message_byIsUnreadIndex"])
    }

    // MARK: - Recording

    private func makeStore() throws -> (stack: TestCoreDataStack, conversationID: UUID) {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let context = stack.viewContext
        let conversationID: UUID = try context.performAndWait {
            let conversation = ConversationBuilder().build(in: context)
            for index in 0..<5 {
                MessageBuilder().withId("recorded-\(index)").inConversation(conversation).build(in: context)
            }
            try context.save()
            let id = conversation.id
            context.reset()
            return id
        }
        return (stack, conversationID)
    }

    private func fetchMessageIDs(_ predicate: NSPredicate, in context: NSManagedObjectContext) throws -> [String] {
        try context.performAndWait {
            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = predicate
            return try context.fetch(request).map(\.id)
        }
    }

    /// The whole reason for the recorder: a real fetch on a real SQLite store
    /// comes back with the plan SQLite made for it. A lookup by the unique
    /// `id` is a search of an index; a filter on an attribute with no index
    /// reads the table from one end.
    ///
    /// Revert-check: `DebugSwitch.setLevel(4)` in the recorder's `Session`
    /// (at level 3 Core Data writes the statements and no plan rows, and both
    /// `XCTUnwrap`s fail), and the `dup2` that points standard error at the
    /// log file.
    func testRecord_sqliteFetches_reportTheirPlans() throws {
        let (stack, _) = try makeStore()
        let context = stack.viewContext

        var found: [String] = []
        let lookupPlans = try SQLiteQueryPlanRecorder.record {
            found = try fetchMessageIDs(MessagePredicates.id("recorded-3"), in: context)
        }
        XCTAssertEqual(found, ["recorded-3"])
        let lookup = try XCTUnwrap(lookupPlans.first { $0.reads("ZMESSAGE") }, "\(lookupPlans)")
        XCTAssertEqual(lookup.scans(of: "ZMESSAGE"), [], "\(lookup)")
        XCTAssertFalse(lookup.indexes(on: "ZMESSAGE").isEmpty, "\(lookup)")

        let filterPlans = try SQLiteQueryPlanRecorder.record {
            found = try fetchMessageIDs(NSPredicate(format: "subject == %@", "Test Subject"), in: context)
        }
        XCTAssertEqual(found.count, 5)
        let filter = try XCTUnwrap(filterPlans.first { $0.reads("ZMESSAGE") }, "\(filterPlans)")
        XCTAssertEqual(filter.scans(of: "ZMESSAGE").count, 1, "\(filter)")
    }

    /// The async form records across suspensions, as the transcript's page
    /// loader needs.
    ///
    /// The two statements are asked for by their SQL and the plans are never
    /// counted: a recording is of the whole process, and this suite runs
    /// after thousands of tests, any of which can have left a task that
    /// fetches messages from a SQLite store while this one records.
    ///
    /// Revert-check: the same two lines as the test above, in the async
    /// `record`'s session.
    func testRecord_asyncBody_reportsThePlansOfWhatRanInside() async throws {
        let (stack, conversationID) = try makeStore()
        let context = stack.newBackgroundContext()

        var page: VirtualScrollMessagePage?
        let plans = try await SQLiteQueryPlanRecorder.record {
            page = await VirtualScrollState.loadMessagePage(
                conversationId: conversationID.uuidString,
                range: 0..<5,
                in: context
            )
        }

        XCTAssertEqual(page?.messageIDs.count, 5)
        XCTAssertEqual(page?.totalCount, 5)
        let messagePlans = plans.filter { $0.reads("ZMESSAGE") }
        XCTAssertTrue(messagePlans.contains { $0.sql.hasPrefix("SELECT COUNT(") }, "\(plans)")
        XCTAssertTrue(messagePlans.contains { !$0.sql.hasPrefix("SELECT COUNT(") }, "\(plans)")
    }

    /// What identifies the file standard error is going to.
    private func standardErrorIdentity() throws -> [UInt64] {
        var status = stat()
        guard fstat(STDERR_FILENO, &status) == 0 else {
            throw POSIXError(.EBADF)
        }
        return [UInt64(truncatingIfNeeded: status.st_dev), UInt64(truncatingIfNeeded: status.st_ino)]
    }

    /// Recording is over when `record` returns, however it returns: the
    /// debug level is back where it was and standard error goes where it went
    /// before. Left on, level 4 would explain and log every statement of every
    /// later test in the process, into a file nobody reads.
    ///
    /// Revert-check: `_ = session.end()` in the `catch` of either `record`
    /// (the first pair of assertions), and `DebugSwitch.setLevel(savedLevel)`
    /// or `restoreStandardError()` in `Session.end()` (both pairs).
    func testRecord_returningOrThrowing_restoresTheDebugLevelAndStandardError() throws {
        struct BodyError: Error {}
        let (stack, _) = try makeStore()
        let context = stack.viewContext
        let levelBefore = try SQLiteQueryPlanRecorder.currentDebugLevel()
        let standardErrorBefore = try standardErrorIdentity()
        // The recordings of the tests that ran before this one in the process
        // ended too. Without this, a recorder that never turns the level off
        // hands this test a "before" of 4 and passes it.
        XCTAssertLessThan(levelBefore, 4, "An earlier recording left Core Data's SQL debugging on")

        XCTAssertThrowsError(
            try SQLiteQueryPlanRecorder.record {
                _ = try fetchMessageIDs(MessagePredicates.id("recorded-1"), in: context)
                throw BodyError()
            }
        ) { error in
            XCTAssertTrue(error is BodyError)
        }
        XCTAssertEqual(try SQLiteQueryPlanRecorder.currentDebugLevel(), levelBefore)
        XCTAssertEqual(try standardErrorIdentity(), standardErrorBefore)

        let plans = try SQLiteQueryPlanRecorder.record {
            XCTAssertEqual(try SQLiteQueryPlanRecorder.currentDebugLevel(), 4)
            XCTAssertNotEqual(try standardErrorIdentity(), standardErrorBefore)
            _ = try fetchMessageIDs(MessagePredicates.id("recorded-4"), in: context)
        }
        // At least the lookup's: other work in the process can add plans to a
        // recording, so they are not counted.
        XCTAssertTrue(plans.contains { $0.reads("ZMESSAGE") }, "\(plans)")
        XCTAssertEqual(try SQLiteQueryPlanRecorder.currentDebugLevel(), levelBefore)
        XCTAssertEqual(try standardErrorIdentity(), standardErrorBefore)
    }
}
