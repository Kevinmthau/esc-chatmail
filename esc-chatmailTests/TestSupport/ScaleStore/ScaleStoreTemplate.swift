import Foundation
import CoreData
@testable import esc_chatmail

/// One seeded store per shape for the whole test process, and a copy of it
/// for each test.
///
/// Seeding an S2 store takes tens of seconds, so it happens once, the first
/// time a test asks. Each test then works on its own copy of the file: a test
/// that persists, archives or deletes cannot change what the next one reads,
/// and on APFS the copy is a clone, which costs no time and no disk until
/// pages are written.
final class ScaleStoreTemplate: @unchecked Sendable {
    /// Whether SQLite has statistics for the store's tables.
    enum Statistics {
        /// No `sqlite_stat1` table: a new install, a reset store, or any
        /// store whose daily background ANALYZE has not run yet. SQLite plans
        /// from the schema alone.
        case none
        /// `ANALYZE` has run over the seeded rows, as the daily maintenance
        /// task does.
        case analyzed
    }

    static let s2 = ScaleStoreTemplate(shape: .s2)

    let shape: ScaleStoreShape

    /// Guards `seeded`, and is held while the store is seeded so a second
    /// caller waits for the first one's store.
    private let lock = NSLock()
    private var seeded: (storeURL: URL, manifest: ScaleStoreManifest)?

    init(shape: ScaleStoreShape) {
        self.shape = shape
    }

    /// A stack over a new copy of the seeded store, and what the store holds.
    func makeStack(
        statistics: Statistics = .none
    ) throws -> (stack: TestCoreDataStack, manifest: ScaleStoreManifest) {
        let template = try seededStore()
        let copyURL = TestCoreDataStack.makeTemporarySQLiteStoreURL()
        for suffix in Self.storeFileSuffixes {
            let source = URL(fileURLWithPath: template.storeURL.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: copyURL.path + suffix))
        }
        if statistics == .analyzed {
            // On the copy, before Core Data opens it: a connection reads the
            // statistics when it reads the schema.
            try SQLiteDatabase(path: copyURL.path).execute("ANALYZE")
        }
        return (TestCoreDataStack(storeKind: .sqliteStore(at: copyURL)), template.manifest)
    }

    private static let storeFileSuffixes = ["", "-wal", "-shm"]

    private func seededStore() throws -> (storeURL: URL, manifest: ScaleStoreManifest) {
        lock.lock()
        defer { lock.unlock() }
        if let seeded {
            return seeded
        }

        let storeURL = TestCoreDataStack.makeTemporarySQLiteStoreURL()
        let stack = TestCoreDataStack(storeKind: .sqliteStore(at: storeURL))
        let manifest = try ScaleStoreSeeder.seed(shape, in: stack.newBackgroundContext())
        // Close the store, so the file is whole and at rest when it is copied.
        let coordinator = stack.persistentContainer.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
        let result = (storeURL, manifest)
        seeded = result
        return result
    }
}
