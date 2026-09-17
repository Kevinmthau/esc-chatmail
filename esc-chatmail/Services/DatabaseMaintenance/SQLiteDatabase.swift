import Foundation
import SQLite3

/// Minimal SQLite handle used by `DatabaseMaintenanceService+SQLite.swift` for
/// VACUUM, ANALYZE, and REINDEX.
///
/// Formerly lived in `Models/CoreDataIndexes.swift` next to never-called raw-SQL
/// index, FTS-trigger, and pragma setup against Core Data's Z-tables. That code
/// was removed; indexing is owned by the `<fetchIndex>` declarations in the
/// versioned model, so do not reintroduce hand-written `CREATE INDEX` here.
class SQLiteDatabase {
    private var db: OpaquePointer?

    init(path: String) throws {
        let result = sqlite3_open(path, &db)
        if result != SQLITE_OK {
            throw DatabaseError.cannotOpen(path)
        }
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }

    func execute(_ sql: String) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(sql)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.executeFailed(sql)
        }
    }

    enum DatabaseError: LocalizedError {
        case cannotOpen(String)
        case prepareFailed(String)
        case executeFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let path):
                return "Cannot open database at \(path)"
            case .prepareFailed(let sql):
                return "Failed to prepare SQL: \(sql)"
            case .executeFailed(let sql):
                return "Failed to execute SQL: \(sql)"
            }
        }
    }
}
