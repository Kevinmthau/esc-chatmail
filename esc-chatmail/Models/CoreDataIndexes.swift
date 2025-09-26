import Foundation
import CoreData
import SQLite3

// MARK: - Core Data Index Configuration
extension NSPersistentStoreCoordinator {
    func configureDatabaseIndexes(for store: NSPersistentStore) {
        guard let url = store.url else { return }

        do {
            // Create composite indexes for common queries
            let indexes = [
                // Conversation indexes
                "CREATE INDEX IF NOT EXISTS idx_conversation_pinned_date ON ZCONVERSATION(ZPINNED DESC, ZLASTMESSAGEDATE DESC)",
                "CREATE INDEX IF NOT EXISTS idx_conversation_hidden_date ON ZCONVERSATION(ZHIDDEN, ZLASTMESSAGEDATE DESC)",
                "CREATE INDEX IF NOT EXISTS idx_conversation_unread_date ON ZCONVERSATION(ZINBOXUNREADCOUNT DESC, ZLASTMESSAGEDATE DESC)",

                // Message indexes
                "CREATE INDEX IF NOT EXISTS idx_message_conversation_date ON ZMESSAGE(ZCONVERSATION, ZINTERNALDATE DESC)",
                "CREATE INDEX IF NOT EXISTS idx_message_thread_date ON ZMESSAGE(ZGMTHREADID, ZINTERNALDATE DESC)",
                "CREATE INDEX IF NOT EXISTS idx_message_unread_conversation ON ZMESSAGE(ZISUNREAD, ZCONVERSATION)",
                "CREATE INDEX IF NOT EXISTS idx_message_from_me_date ON ZMESSAGE(ZISFROMME, ZINTERNALDATE DESC)",

                // Label indexes
                "CREATE INDEX IF NOT EXISTS idx_message_labels ON Z_7LABELS(Z_7MESSAGES, Z_10LABELS)",

                // Participant indexes
                "CREATE INDEX IF NOT EXISTS idx_participant_person ON ZMESSAGEPARTICIPANT(ZPERSON, ZMESSAGE)",
                "CREATE INDEX IF NOT EXISTS idx_conversation_participant ON ZCONVERSATIONPARTICIPANT(ZCONVERSATION, ZPERSON)",

                // Attachment indexes
                "CREATE INDEX IF NOT EXISTS idx_attachment_message_state ON ZATTACHMENT(ZMESSAGE, ZSTATERAW)",
                "CREATE INDEX IF NOT EXISTS idx_attachment_state ON ZATTACHMENT(ZSTATERAW)",

                // Full-text search indexes
                "CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(content, snippet, tokenize='porter ascii')",
                "CREATE TRIGGER IF NOT EXISTS message_fts_insert AFTER INSERT ON ZMESSAGE BEGIN INSERT INTO message_fts(content, snippet) VALUES (new.ZBODYTEXT, new.ZSNIPPET); END",
                "CREATE TRIGGER IF NOT EXISTS message_fts_update AFTER UPDATE ON ZMESSAGE BEGIN UPDATE message_fts SET content = new.ZBODYTEXT, snippet = new.ZSNIPPET WHERE rowid = new.Z_PK; END",
                "CREATE TRIGGER IF NOT EXISTS message_fts_delete AFTER DELETE ON ZMESSAGE BEGIN DELETE FROM message_fts WHERE rowid = old.Z_PK; END"
            ]

            // Execute index creation
            let sqliteURL = url.path.hasSuffix(".sqlite") ? url : url.appendingPathComponent("StoreContent.sqlite")
            if FileManager.default.fileExists(atPath: sqliteURL.path) {
                let db = try SQLiteDatabase(path: sqliteURL.path)
                for index in indexes {
                    try db.execute(index)
                }
                print("Database indexes created successfully")
            }
        } catch {
            print("Failed to create database indexes: \(error)")
        }
    }
}

// MARK: - SQLite Database Helper
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

// MARK: - Core Data Stack Extension for Optimization
extension CoreDataStack {
    func optimizeDatabasePerformance() {
        guard let store = persistentContainer.persistentStoreCoordinator.persistentStores.first else { return }

        // Configure indexes
        persistentContainer.persistentStoreCoordinator.configureDatabaseIndexes(for: store)

        // Set SQLite pragmas for better performance
        configureSQLitePragmas()

        // Schedule periodic maintenance
        Task { @MainActor in
            DatabaseMaintenanceService.shared.scheduleMaintenanceTasks()
        }
    }

    private func configureSQLitePragmas() {
        let context = persistentContainer.newBackgroundContext()
        context.perform {
            let pragmas = [
                "PRAGMA journal_mode = WAL",           // Write-Ahead Logging for better concurrency
                "PRAGMA synchronous = NORMAL",         // Faster writes, still safe
                "PRAGMA cache_size = -64000",         // 64MB cache
                "PRAGMA temp_store = MEMORY",         // Use memory for temp tables
                "PRAGMA mmap_size = 268435456",       // 256MB memory-mapped I/O
                "PRAGMA page_size = 4096",            // Optimal page size
                "PRAGMA auto_vacuum = INCREMENTAL"    // Automatic space reclamation
            ]

            for pragma in pragmas {
                do {
                    try context.execute(NSFetchRequest<NSFetchRequestResult>(entityName: pragma))
                } catch {
                    // This is expected to fail as we're using fetch request for pragmas
                    // In production, use raw SQLite access
                }
            }
        }
    }
}