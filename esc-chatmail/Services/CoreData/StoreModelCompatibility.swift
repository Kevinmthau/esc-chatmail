import CoreData
import Foundation

/// Tells a store saved by a newer build from one whose migration failed, after a
/// migration-family load error (`CoreDataErrorClassifier.RecoveryAction.migrationFailed`).
///
/// The answer decides only what the launch screen says. The store is kept either way, and
/// either may be reset by the user behind the confirmation once retrying has not helped
/// (Kevin, 2026-11-24):
///
/// - The store says a newer model wrote it: the model ordinal stamped in its metadata
///   (`modelOrdinalMetadataKey`) is above this build's. `PersistentStoreLoadError
///   .storeFromNewerVersion`, whose notice asks the user to update MushMail.
/// - Anything else that could be read: the migration to this build's model failed.
///   `.migrationFailed`.
/// - The store's metadata could not be read: `.unavailable`, today's answer for a store
///   that cannot be read, with the reset that goes with it.
///
/// "Newer" is decided on that positive evidence alone, never on the store's entity hashes
/// matching no model this build bundles: the first model version was edited in place eight
/// times while it shipped (2026-01 to 2026-07), so a store an old build wrote matches no
/// bundled version either, and its notice would tell the user to install an update that
/// does not exist. The same
/// goes for a store a development build wrote with a model version that changed again
/// before it shipped. A store no build has stamped yet (every store written before this
/// stamp existed) is never "newer".
enum StoreModelCompatibility {
    enum Verdict: Equatable {
        /// The store's stamp names a model newer than this build's.
        case writtenByNewerModel(storeOrdinal: Int)
        /// No evidence that a newer model wrote it.
        case notNewer
        /// The store's metadata could not be read.
        case unreadable
    }

    static let modelName = "ESCChatmail"

    /// The store-metadata key holding the ordinal of the model that last opened the store
    /// (`CoreDataStack` stamps it after every successful load, and the next save writes it).
    static let modelOrdinalMetadataKey = "MushMailModelVersionOrdinal"

    /// This build's current model version's ordinal, read from the compiled model's
    /// `VersionInfo.plist` (`NSManagedObjectModel_CurrentVersionName`), or nil when it
    /// cannot be read. Read from the plist, not from a loaded model: a second live
    /// `NSManagedObjectModel` in the process makes `+[NSManagedObject entity]` ambiguous.
    static func currentModelOrdinal(in bundle: Bundle = .main) -> Int? {
        guard let modelURL = bundle.url(forResource: modelName, withExtension: "momd"),
              let data = try? Data(contentsOf: modelURL.appendingPathComponent("VersionInfo.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let currentName = plist["NSManagedObjectModel_CurrentVersionName"] as? String else {
            return nil
        }
        return ordinal(ofModelVersionNamed: currentName)
    }

    /// `ESCChatmail` is version 1 and `ESCChatmail N` is version N; any other name has none.
    static func ordinal(ofModelVersionNamed name: String) -> Int? {
        if name == modelName { return 1 }
        let prefix = modelName + " "
        guard name.hasPrefix(prefix), let ordinal = Int(name.dropFirst(prefix.count)), ordinal > 0 else {
            return nil
        }
        return ordinal
    }

    static func verdict(forStoreMetadata metadata: [String: Any], currentModelOrdinal: Int?) -> Verdict {
        guard let storeOrdinal = (metadata[modelOrdinalMetadataKey] as? NSNumber)?.intValue,
              let currentModelOrdinal,
              storeOrdinal > currentModelOrdinal else {
            return .notNewer
        }
        return .writtenByNewerModel(storeOrdinal: storeOrdinal)
    }

    static func verdict(forStoreAt storeURL: URL, currentModelOrdinal: Int?) -> Verdict {
        do {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType,
                at: storeURL,
                options: nil
            )
            return verdict(forStoreMetadata: metadata, currentModelOrdinal: currentModelOrdinal)
        } catch {
            Log.error("Could not read the store's metadata after a failed migration", category: .coreData, error: error)
            return .unreadable
        }
    }

    /// The error a migration-family load failure latches. The store is never touched here.
    static func loadError(
        forMigrationFailure error: Error,
        storeAt storeURL: URL?,
        currentModelOrdinal: Int?
    ) -> PersistentStoreLoadError {
        guard let storeURL else { return .unavailable(error) }
        switch verdict(forStoreAt: storeURL, currentModelOrdinal: currentModelOrdinal) {
        case .writtenByNewerModel(let storeOrdinal):
            Log.error(
                "A newer model (version \(storeOrdinal)) wrote the store than this build has; keeping it",
                category: .coreData,
                error: error
            )
            return .storeFromNewerVersion(error)
        case .notNewer:
            Log.error("The store's migration failed; keeping it", category: .coreData, error: error)
            return .migrationFailed(error)
        case .unreadable:
            return .unavailable(error)
        }
    }

    /// `metadata` with this build's ordinal stamped in, or nil when it already holds it or
    /// the ordinal is unknown.
    static func metadataStamping(_ currentModelOrdinal: Int?, into metadata: [String: Any]) -> [String: Any]? {
        guard let currentModelOrdinal,
              (metadata[modelOrdinalMetadataKey] as? NSNumber)?.intValue != currentModelOrdinal else {
            return nil
        }
        var stamped = metadata
        stamped[modelOrdinalMetadataKey] = currentModelOrdinal
        return stamped
    }
}
