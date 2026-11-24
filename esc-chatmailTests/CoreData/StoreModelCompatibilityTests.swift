import XCTest
import CoreData
@testable import esc_chatmail

/// `StoreModelCompatibility`: which bundled model version wrote a store, read from the
/// compiled model's `VersionInfo.plist` without loading a second model.
final class StoreModelCompatibilityTests: XCTestCase {
    func testBundledVersionHashes_listEveryShippedVersionAndTheCurrentOne() throws {
        let versions = try XCTUnwrap(StoreModelCompatibility.bundledVersionHashes())
        let current = TestCoreDataStack.sharedModelVersionHashes

        XCTAssertTrue(versions.keys.contains("ESCChatmail 5"))
        XCTAssertTrue(
            versions.values.contains(current),
            "This build's own model must be among the versions it lists"
        )
    }

    func testVerdict_metadataOfTheCurrentModel_isABundledVersion() throws {
        let metadata: [String: Any] = [NSStoreModelVersionHashesKey: TestCoreDataStack.sharedModelVersionHashes]

        let verdict = StoreModelCompatibility.verdict(
            forStoreMetadata: metadata,
            bundledVersionHashes: StoreModelCompatibility.bundledVersionHashes()
        )

        guard case .bundledVersion = verdict else {
            return XCTFail("Expected a bundled version, got \(verdict)")
        }
    }

    func testVerdict_anEntityNoBundledVersionHas_isNoBundledVersion() {
        var hashes = TestCoreDataStack.sharedModelVersionHashes
        hashes["EntityFromANewerBuild"] = Data(repeating: 1, count: 32)

        let verdict = StoreModelCompatibility.verdict(
            forStoreMetadata: [NSStoreModelVersionHashesKey: hashes],
            bundledVersionHashes: StoreModelCompatibility.bundledVersionHashes()
        )

        XCTAssertEqual(verdict, .noBundledVersion)
    }

    // Revert-check: the `bundledVersionHashes` and store-hash guard of
    // `StoreModelCompatibility.verdict(forStoreMetadata:…)`. Without it a read that failed
    // compares as "matches nothing" and is taken for a newer build's store, which nothing
    // ever lets the user reset.
    func testVerdict_unreadableInputs_areUnreadableNeverANewerBuild() {
        let current: [String: Any] = [NSStoreModelVersionHashesKey: TestCoreDataStack.sharedModelVersionHashes]

        XCTAssertEqual(StoreModelCompatibility.verdict(forStoreMetadata: current, bundledVersionHashes: nil), .unreadable)
        XCTAssertEqual(
            StoreModelCompatibility.verdict(forStoreMetadata: [:], bundledVersionHashes: StoreModelCompatibility.bundledVersionHashes()),
            .unreadable
        )
    }

    func testLoadError_storeMetadataCannotBeRead_isUnavailable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreModelCompatibilityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notADatabase = directory.appendingPathComponent("Mailbox.sqlite")
        try Data("not a database".utf8).write(to: notADatabase)
        let failure = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreIncompatibleVersionHashError)

        let loadError = StoreModelCompatibility.loadError(
            forMigrationFailure: failure,
            storeAt: notADatabase,
            bundledVersionHashes: StoreModelCompatibility.bundledVersionHashes()
        )

        guard case .unavailable = loadError else {
            return XCTFail("Expected unavailable, got \(loadError)")
        }
    }
}
