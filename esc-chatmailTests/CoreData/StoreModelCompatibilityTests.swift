import XCTest
import CoreData
@testable import esc_chatmail

/// `StoreModelCompatibility`: a store is "a newer build's" only when it says so (the model
/// ordinal stamped in its metadata is above this build's), never because its hashes match
/// no bundled model.
final class StoreModelCompatibilityTests: XCTestCase {
    func testCurrentModelOrdinal_isReadFromTheCompiledModel() throws {
        let ordinal = try XCTUnwrap(StoreModelCompatibility.currentModelOrdinal())

        XCTAssertGreaterThanOrEqual(ordinal, 6, "ESCChatmail 6 shipped before this was written")
    }

    func testOrdinalOfModelVersionNamed_readsTheVersionNumber() {
        XCTAssertEqual(StoreModelCompatibility.ordinal(ofModelVersionNamed: "ESCChatmail"), 1)
        XCTAssertEqual(StoreModelCompatibility.ordinal(ofModelVersionNamed: "ESCChatmail 6"), 6)
        XCTAssertEqual(StoreModelCompatibility.ordinal(ofModelVersionNamed: "ESCChatmail 12"), 12)
        XCTAssertNil(StoreModelCompatibility.ordinal(ofModelVersionNamed: "ESCChatmail draft"))
        XCTAssertNil(StoreModelCompatibility.ordinal(ofModelVersionNamed: "Other 3"))
    }

    func testVerdict_stampAboveThisBuild_isWrittenByNewerModel() {
        let metadata: [String: Any] = [StoreModelCompatibility.modelOrdinalMetadataKey: 7]

        XCTAssertEqual(
            StoreModelCompatibility.verdict(forStoreMetadata: metadata, currentModelOrdinal: 6),
            .writtenByNewerModel(storeOrdinal: 7)
        )
    }

    // Revert-check: the `storeOrdinal > currentModelOrdinal` condition of
    // `StoreModelCompatibility.verdict(forStoreMetadata:currentModelOrdinal:)`. A store this
    // build or an older one stamped, whose migration failed, would then never be resettable.
    func testVerdict_stampAtOrBelowThisBuild_isNotNewer() {
        for stamp in [1, 5, 6] {
            let metadata: [String: Any] = [StoreModelCompatibility.modelOrdinalMetadataKey: stamp]

            XCTAssertEqual(
                StoreModelCompatibility.verdict(forStoreMetadata: metadata, currentModelOrdinal: 6),
                .notNewer,
                "stamp \(stamp)"
            )
        }
    }

    /// Every store written before the stamp existed has none, including one a build of the
    /// first model wrote before that model was edited in place, whose hashes no bundled
    /// version has. Read as "a newer build's", it could never be reset.
    ///
    /// Revert-check: the `let storeOrdinal = …` binding in the guard of
    /// `StoreModelCompatibility.verdict(forStoreMetadata:currentModelOrdinal:)`, read as
    /// "newer" when absent.
    func testVerdict_noStampOrNoOrdinalOfOurOwn_isNotNewer() {
        XCTAssertEqual(StoreModelCompatibility.verdict(forStoreMetadata: [:], currentModelOrdinal: 6), .notNewer)
        XCTAssertEqual(
            StoreModelCompatibility.verdict(
                forStoreMetadata: [StoreModelCompatibility.modelOrdinalMetadataKey: 9],
                currentModelOrdinal: nil
            ),
            .notNewer
        )
    }

    func testMetadataStamping_addsOrReplacesTheStampOnlyWhenItDiffers() {
        let stamped = StoreModelCompatibility.metadataStamping(6, into: ["other": "kept"])
        XCTAssertEqual((stamped?[StoreModelCompatibility.modelOrdinalMetadataKey] as? NSNumber)?.intValue, 6)
        XCTAssertEqual(stamped?["other"] as? String, "kept")

        XCTAssertNil(StoreModelCompatibility.metadataStamping(6, into: [StoreModelCompatibility.modelOrdinalMetadataKey: 6]))
        XCTAssertNil(StoreModelCompatibility.metadataStamping(nil, into: [:]))
        XCTAssertNotNil(StoreModelCompatibility.metadataStamping(7, into: [StoreModelCompatibility.modelOrdinalMetadataKey: 6]))
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
            currentModelOrdinal: 6
        )

        guard case .unavailable = loadError else {
            return XCTFail("Expected unavailable, got \(loadError)")
        }
    }
}
