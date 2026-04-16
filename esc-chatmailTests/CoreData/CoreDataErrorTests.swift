import XCTest
@testable import esc_chatmail

final class CoreDataErrorTests: XCTestCase {

    private struct DummyError: LocalizedError {
        var errorDescription: String? { "underlying explanation" }
    }

    func testErrorDescription_includesUnderlyingMessageForStoreLoadFailed() {
        let error = CoreDataError.storeLoadFailed(DummyError())
        XCTAssertTrue(error.errorDescription?.contains("underlying explanation") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("data store") ?? false)
    }

    func testErrorDescription_includesUnderlyingMessageForMigrationFailed() {
        let error = CoreDataError.migrationFailed(DummyError())
        XCTAssertTrue(error.errorDescription?.contains("migrate") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("underlying explanation") ?? false)
    }

    func testErrorDescription_includesUnderlyingMessageForSaveFailed() {
        let error = CoreDataError.saveFailed(DummyError())
        XCTAssertTrue(error.errorDescription?.contains("save") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("underlying explanation") ?? false)
    }

    func testErrorDescription_stackDestroyedHasMessage() {
        let error = CoreDataError.stackDestroyed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }

    func testErrorDescription_entityCreationFailedIncludesEntityName() {
        let error = CoreDataError.entityCreationFailed("Message")
        XCTAssertTrue(error.errorDescription?.contains("Message") ?? false)
    }

    // MARK: - Recovery suggestions

    func testRecoverySuggestion_persistentFailures_recommendRestart() {
        let cases: [CoreDataError] = [
            .storeLoadFailed(DummyError()),
            .migrationFailed(DummyError()),
            .persistentFailure(DummyError()),
            .stackDestroyed,
            .entityCreationFailed("X")
        ]
        for error in cases {
            let suggestion = error.recoverySuggestion ?? ""
            XCTAssertTrue(
                suggestion.lowercased().contains("restart") || suggestion.lowercased().contains("reinstall"),
                "Expected restart/reinstall suggestion for \(error), got: \(suggestion)"
            )
        }
    }

    func testRecoverySuggestion_transientFailures_suggestRetry() {
        let cases: [CoreDataError] = [
            .saveFailed(DummyError()),
            .transientFailure(DummyError())
        ]
        for error in cases {
            let suggestion = error.recoverySuggestion ?? ""
            XCTAssertTrue(
                suggestion.lowercased().contains("try again"),
                "Expected retry suggestion for \(error), got: \(suggestion)"
            )
        }
    }
}
