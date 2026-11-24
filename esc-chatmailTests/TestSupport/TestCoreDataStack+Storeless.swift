import CoreData
import Foundation
@testable import esc_chatmail

/// Containers whose coordinator has no store attached, for the checks that refuse to read
/// one (`CoreDataStack.requireAttachedStore(in:)`).
extension TestCoreDataStack {
    /// A SQLite container on the process-wide model that is never loaded: its coordinator
    /// has no store, as after a load that failed and was kept. Its store's directory is
    /// named with the `TestCoreDataStack-` prefix and is not created, so nothing is left on
    /// disk unless something loads the container.
    static func makeStorelessContainer() -> (container: NSPersistentContainer, storeURL: URL) {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestCoreDataStack-storeless-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Mailbox.sqlite")
        return (makeUnloadedSQLiteContainer(storeURL: storeURL), storeURL)
    }

    /// Writes an empty store and puts a directory where its write-ahead log belongs, so a
    /// load fails with SQLITE_CANTOPEN and is kept (`.unavailable`) without attaching a
    /// store. The caller removes the returned store's directory.
    static func makeUnopenableSQLiteStore() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestCoreDataStack-unopenable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("Mailbox.sqlite")
        let seed = makeUnloadedSQLiteContainer(storeURL: storeURL)
        seed.persistentStoreDescriptions[0].setOption(
            ["journal_mode": "DELETE"] as NSDictionary,
            forKey: NSSQLitePragmasOption
        )
        var loadError: Error?
        seed.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        for store in seed.persistentStoreCoordinator.persistentStores {
            try seed.persistentStoreCoordinator.remove(store)
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: storeURL.path + "-wal"),
            withIntermediateDirectories: false
        )
        return storeURL
    }
}
