import Foundation
import SQLite3
import os

/// Minimal SQLite handle used by `DatabaseMaintenanceService+SQLite.swift` for
/// ANALYZE. The weekly VACUUM it also ran is retired
/// (`DatabaseMaintenanceService.retiredVacuumTaskIdentifier`).
///
/// Formerly lived in `Models/CoreDataIndexes.swift` next to never-called raw-SQL
/// index, FTS-trigger, and pragma setup against Core Data's Z-tables. That code
/// was removed; indexing is owned by the `<fetchIndex>` declarations in the
/// versioned model, so do not reintroduce hand-written `CREATE INDEX` here.
///
/// `@unchecked Sendable`: the connection is used by one caller at a time
/// (`execute` is called from the one task that made the handle), and the only
/// thing another thread touches is `isInterrupted`, which is read and written
/// under its lock.
final class SQLiteDatabase: @unchecked Sendable {
    private let db: OpaquePointer
    /// Set by `interrupt()` and never cleared: a handle that was told to stop
    /// runs nothing more.
    private let isInterrupted = OSAllocatedUnfairLock(initialState: false)

    /// How many SQLite virtual-machine steps run between two looks at
    /// `isInterrupted`. Small enough that a statement stops within
    /// milliseconds, large enough that the look costs nothing measurable.
    private static let progressStepInterval: Int32 = 1_000

    /// - Parameter busyTimeoutMilliseconds: how long a statement waits for
    ///   another connection's write to finish before it fails with
    ///   `SQLITE_BUSY`. With none, a statement that met a Core Data save in
    ///   progress failed at once.
    init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        var handle: OpaquePointer?
        // Read-write and never create: the path is the app's store, and a
        // path that names nothing must fail, not leave an empty file there.
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw DatabaseError.cannotOpen(path: path, code: result, message: message)
        }
        db = handle
        sqlite3_busy_timeout(handle, busyTimeoutMilliseconds)
        // SQLite calls this on the thread running the statement, every
        // `progressStepInterval` steps, and stops the statement with
        // `SQLITE_INTERRUPT` once it returns non-zero. A flag read here in
        // place of `sqlite3_interrupt`: that call does nothing when it lands
        // before the statement has started, and the statement then runs to
        // its end.
        sqlite3_progress_handler(
            handle,
            Self.progressStepInterval,
            { context in
                guard let context else { return 0 }
                let database = Unmanaged<SQLiteDatabase>.fromOpaque(context).takeUnretainedValue()
                return database.isInterrupted.withLock { $0 } ? 1 : 0
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    deinit {
        sqlite3_close(db)
    }

    /// Stops the statement that is running, if one is, and refuses every
    /// later one. Safe to call from any thread.
    func interrupt() {
        isInterrupted.withLock { $0 = true }
    }

    func execute(_ sql: String) throws {
        guard !isInterrupted.withLock({ $0 }) else {
            throw DatabaseError.interrupted(sql)
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(sql: sql, code: sqlite3_errcode(db), message: lastErrorMessage())
        }

        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            if result == SQLITE_INTERRUPT {
                throw DatabaseError.interrupted(sql)
            }
            throw DatabaseError.executeFailed(sql: sql, code: result, message: lastErrorMessage())
        }
    }

    /// Runs `sql`, stopping it if the calling task is cancelled.
    func executeUnlessCancelled(_ sql: String) async throws {
        try await withTaskCancellationHandler {
            try execute(sql)
        } onCancel: {
            interrupt()
        }
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }

    enum DatabaseError: LocalizedError, Equatable {
        case cannotOpen(path: String, code: Int32, message: String)
        case prepareFailed(sql: String, code: Int32, message: String)
        /// The statement ran and SQLite refused it: `SQLITE_BUSY` when
        /// another connection held the write lock for longer than the busy
        /// timeout, `SQLITE_FULL` on a full disk.
        case executeFailed(sql: String, code: Int32, message: String)
        /// The statement was stopped by `interrupt()`, or never started
        /// because the handle had been interrupted. Not a fault in the
        /// store: the work was cancelled.
        case interrupted(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let path, let code, let message):
                return "Cannot open database at \(path) (SQLite \(code): \(message))"
            case .prepareFailed(let sql, let code, let message):
                return "Failed to prepare SQL: \(sql) (SQLite \(code): \(message))"
            case .executeFailed(let sql, let code, let message):
                return "Failed to execute SQL: \(sql) (SQLite \(code): \(message))"
            case .interrupted(let sql):
                return "Interrupted SQL: \(sql)"
            }
        }
    }
}
