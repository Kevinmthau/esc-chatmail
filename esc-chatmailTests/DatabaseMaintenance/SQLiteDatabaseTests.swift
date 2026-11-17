import XCTest
import SQLite3
@testable import esc_chatmail

/// `SQLiteDatabase` is the handle the daily ANALYZE runs on, against the
/// app's own store while Core Data has it open. These run it against a
/// throwaway database file in the test's own directory.
final class SQLiteDatabaseTests: XCTestCase {
    private var directory: URL!
    private var databasePath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databasePath = directory.appendingPathComponent("store.sqlite").path
        try Self.run(
            """
            CREATE TABLE item(value INTEGER); INSERT INTO item VALUES (1), (2), (3);
            CREATE TABLE once(value INTEGER PRIMARY KEY); INSERT INTO once VALUES (1);
            """,
            atPath: databasePath
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        directory = nil
        databasePath = nil
        try super.tearDownWithError()
    }

    func testExecute_analyze_succeeds() throws {
        let database = try SQLiteDatabase(path: databasePath)

        XCTAssertNoThrow(try database.execute("ANALYZE"))
    }

    // Revert-check: `SQLITE_OPEN_READWRITE` with no `SQLITE_OPEN_CREATE` in
    // `SQLiteDatabase.init`. `sqlite3_open` creates the file it is asked for,
    // so a wrong store path left an empty database beside the store.
    func testInit_pathThatNamesNothing_failsAndCreatesNoFile() {
        let missing = directory.appendingPathComponent("missing.sqlite").path

        XCTAssertThrowsError(try SQLiteDatabase(path: missing)) { error in
            guard case SQLiteDatabase.DatabaseError.cannotOpen(let path, let code, _) = error else {
                return XCTFail("Expected cannotOpen, got \(error)")
            }
            XCTAssertEqual(path, missing)
            XCTAssertEqual(code, SQLITE_CANTOPEN)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }

    // Revert-check: the `code` and `message` that `SQLiteDatabase.execute`
    // reads from the connection. The error named the statement alone, so a
    // full disk and a locked store were the same line in the log.
    func testExecute_statementSQLiteRefuses_reportsItsCodeAndMessage() throws {
        let database = try SQLiteDatabase(path: databasePath)

        XCTAssertThrowsError(try database.execute("INSERT INTO once VALUES (1)")) { error in
            guard case SQLiteDatabase.DatabaseError.executeFailed(_, let code, let message) = error else {
                return XCTFail("Expected executeFailed, got \(error)")
            }
            XCTAssertEqual(code, SQLITE_CONSTRAINT)
            XCTAssertTrue(message.contains("once.value"), message)
        }
        XCTAssertThrowsError(try database.execute("NOT SQL AT ALL")) { error in
            guard case SQLiteDatabase.DatabaseError.prepareFailed(_, let code, let message) = error else {
                return XCTFail("Expected prepareFailed, got \(error)")
            }
            XCTAssertEqual(code, SQLITE_ERROR)
            XCTAssertTrue(message.contains("syntax error"), message)
        }
    }

    // HONEST SCOPE: pins the code a locked store is reported with, and has
    // no revert target. With no busy handler the statement fails with the
    // same `SQLITE_BUSY`, only at once. That a statement waits out a short
    // lock was not made into a test: it needs a second thread that releases
    // the lock on a timer.
    //
    // The lock is met when the statement is prepared, which reads the
    // schema, so that is the error it arrives as.
    func testExecute_storeLockedByAnotherConnection_reportsBusy() throws {
        var holder: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databasePath, &holder), SQLITE_OK)
        defer { sqlite3_close(holder) }
        XCTAssertEqual(sqlite3_exec(holder, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        defer { sqlite3_exec(holder, "ROLLBACK", nil, nil, nil) }
        let database = try SQLiteDatabase(path: databasePath, busyTimeoutMilliseconds: 20)

        XCTAssertThrowsError(try database.execute("ANALYZE")) { error in
            switch error as? SQLiteDatabase.DatabaseError {
            case .prepareFailed(_, let code, _), .executeFailed(_, let code, _):
                XCTAssertEqual(code, SQLITE_BUSY)
            default:
                XCTFail("Expected a failed statement, got \(error)")
            }
        }
    }

    // Revert-check: the `isInterrupted` guard at the top of
    // `SQLiteDatabase.execute`. A handle told to stop runs nothing more.
    func testExecute_afterInterrupt_runsNothing() throws {
        let database = try SQLiteDatabase(path: databasePath)

        database.interrupt()

        XCTAssertThrowsError(try database.execute("INSERT INTO item VALUES (4)")) { error in
            XCTAssertEqual(
                error as? SQLiteDatabase.DatabaseError,
                .interrupted("INSERT INTO item VALUES (4)")
            )
        }
        XCTAssertEqual(try Self.count("SELECT count(*) FROM item", atPath: databasePath), 3)
    }

    // Revert-check: the progress handler `SQLiteDatabase.init` installs.
    // The statement counts to thirty million, which takes seconds. With
    // nothing to stop it, it finishes and the test fails on that; with the
    // handler it ends in `.interrupted` a few thousand steps after the task
    // is cancelled.
    //
    // The cancellation is sent once the statement has had time to start. A
    // cancellation that arrives before it starts is refused by the guard
    // pinned above, which would pass this test without the handler, so the
    // wait is what makes this the handler's test. It is a real delay
    // because nothing reports that SQLite has begun stepping.
    func testExecuteUnlessCancelled_cancelledWhileAStatementRuns_stopsIt() async throws {
        let database = try SQLiteDatabase(path: databasePath)
        let long = """
            WITH RECURSIVE counter(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM counter WHERE n < 30000000) \
            SELECT count(*) FROM counter
            """

        let statement = Task.detached {
            try await database.executeUnlessCancelled(long)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        statement.cancel()

        do {
            try await statement.value
            XCTFail("The statement ran to its end: nothing stopped it")
        } catch {
            XCTAssertEqual(error as? SQLiteDatabase.DatabaseError, .interrupted(long))
        }
    }

    // Revert-check: the busy handler `SQLiteDatabase.init` installs in place
    // of `sqlite3_busy_timeout`, and the `isInterruption` reading of the
    // `SQLITE_BUSY` it leaves. The store is locked for the whole test and
    // the handle would wait ten seconds for it. With the timeout nothing
    // ends that wait, and the statement fails ten seconds later: the time
    // assertion fails. With `SQLITE_BUSY` not read as the interrupt's, it
    // is reported as a locked store: the error assertion fails.
    func testExecuteUnlessCancelled_cancelledWhileWaitingForALock_stopsWaiting() async throws {
        var holder: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databasePath, &holder), SQLITE_OK)
        defer { sqlite3_close(holder) }
        XCTAssertEqual(sqlite3_exec(holder, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        defer { sqlite3_exec(holder, "ROLLBACK", nil, nil, nil) }
        let database = try SQLiteDatabase(path: databasePath, busyTimeoutMilliseconds: 10_000)

        let started = Date()
        let statement = Task.detached {
            try await database.executeUnlessCancelled("ANALYZE")
        }
        // Long enough for the statement to be waiting on the lock. One
        // cancelled before it starts is refused by the guard at the top of
        // `execute`, which would pass this test without the handler.
        try await Task.sleep(nanoseconds: 200_000_000)
        statement.cancel()

        do {
            try await statement.value
            XCTFail("The statement ran against a locked store")
        } catch {
            XCTAssertEqual(error as? SQLiteDatabase.DatabaseError, .interrupted("ANALYZE"))
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 5,
            "A cancelled statement must not wait out the busy timeout"
        )
    }

    // MARK: - Helpers

    private static func run(_ sql: String, atPath path: String) throws {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open(path, &handle) == SQLITE_OK,
              sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw XCTSkip("Could not prepare the test database")
        }
    }

    private static func count(_ sql: String, atPath path: String) throws -> Int {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_open(path, &handle) == SQLITE_OK,
              sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw XCTSkip("Could not read the test database")
        }
        return Int(sqlite3_column_int(statement, 0))
    }
}
