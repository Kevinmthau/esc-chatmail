import CoreData
import Foundation

/// Tells a store saved by a newer build from one whose migration failed, after a
/// migration-family load error (`CoreDataErrorClassifier.RecoveryAction.migrationFailed`).
///
/// The answer decides only what the launch screen offers. The store is kept either way:
///
/// - Its model is one of the versions this build bundles: the migration to the current
///   model failed on the user's data. `PersistentStoreLoadError.migrationFailed`, which the
///   user may reset behind the confirmation once retrying has not helped.
/// - Its model is none of them: a newer MushMail saved it (a downgrade, or a development
///   build sharing the Mac's container). `.storeFromNewerVersion`, which nothing resets;
///   only a build that knows its model can open it (Kevin, 2026-11-24).
/// - The store's metadata or this build's list of versions could not be read: nothing
///   proves which, so it is `.unavailable`, today's answer for a store that cannot be read,
///   with the reset that goes with it. A failed read is never taken for "a newer build".
///
/// The versions are read from the compiled model's `VersionInfo.plist`
/// (`NSManagedObjectModel_VersionHashes`: each version's entity hashes), which `momc`
/// writes beside the `.mom` files, rather than by loading each `.mom`: a second live
/// `NSManagedObjectModel` in the process makes `+[NSManagedObject entity]` ambiguous. So
/// every shipped model version must stay in `ESCChatmail.xcdatamodeld`, as CLAUDE.md
/// requires anyway: a version removed from the bundle makes the stores it wrote read as a
/// newer build's.
enum StoreModelCompatibility {
    enum Verdict: Equatable {
        /// The store's entity hashes are those of the named bundled version.
        case bundledVersion(String)
        /// The store's entity hashes match no bundled version.
        case noBundledVersion
        /// The store's metadata, or the bundled versions, could not be read.
        case unreadable
    }

    static let modelName = "ESCChatmail"

    /// Each bundled model version's entity hashes, by version name, or nil when the
    /// compiled model's `VersionInfo.plist` cannot be read.
    static func bundledVersionHashes(in bundle: Bundle = .main) -> [String: [String: Data]]? {
        guard let modelURL = bundle.url(forResource: modelName, withExtension: "momd"),
              let data = try? Data(contentsOf: modelURL.appendingPathComponent("VersionInfo.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let versions = plist["NSManagedObjectModel_VersionHashes"] as? [String: [String: Data]],
              !versions.isEmpty else {
            return nil
        }
        return versions
    }

    static func verdict(
        forStoreMetadata metadata: [String: Any],
        bundledVersionHashes: [String: [String: Data]]?
    ) -> Verdict {
        guard let bundledVersionHashes,
              let storeHashes = metadata[NSStoreModelVersionHashesKey] as? [String: Data],
              !storeHashes.isEmpty else {
            return .unreadable
        }
        // Sorted, so that the answer does not depend on dictionary order.
        for name in bundledVersionHashes.keys.sorted() where bundledVersionHashes[name] == storeHashes {
            return .bundledVersion(name)
        }
        return .noBundledVersion
    }

    static func verdict(
        forStoreAt storeURL: URL,
        bundledVersionHashes: [String: [String: Data]]?
    ) -> Verdict {
        do {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType,
                at: storeURL,
                options: nil
            )
            return verdict(forStoreMetadata: metadata, bundledVersionHashes: bundledVersionHashes)
        } catch {
            Log.error("Could not read the store's metadata after a failed migration", category: .coreData, error: error)
            return .unreadable
        }
    }

    /// The error a migration-family load failure latches. The store is never touched here.
    static func loadError(
        forMigrationFailure error: Error,
        storeAt storeURL: URL?,
        bundledVersionHashes: [String: [String: Data]]?
    ) -> PersistentStoreLoadError {
        guard let storeURL else { return .unavailable(error) }
        switch verdict(forStoreAt: storeURL, bundledVersionHashes: bundledVersionHashes) {
        case .bundledVersion(let name):
            Log.error("Migration from model version \(name) failed; keeping the store", category: .coreData, error: error)
            return .migrationFailed(error)
        case .noBundledVersion:
            Log.error("The store was saved by a newer model than this build has; keeping it", category: .coreData, error: error)
            return .storeFromNewerVersion(error)
        case .unreadable:
            return .unavailable(error)
        }
    }
}
