import XCTest
import CoreData
@testable import esc_chatmail

final class CoreDataRecoveryHandlerTests: XCTestCase {

    private var tempDir: URL!
    private var storeURL: URL!
    private var sut: CoreDataRecoveryHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreDataRecoveryHandlerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("Store.sqlite")
        try Data("payload".utf8).write(to: storeURL)
        sut = CoreDataRecoveryHandler(retryDelay: 0.01, maxLoadAttempts: 3)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        sut = nil
        try super.tearDownWithError()
    }

    // MARK: - handleError

    func testHandleError_recoverableTimeoutWithinAttempts_returnsRetryWithConfiguredDelay() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreTimeoutError)

        let result = sut.handleError(error, currentAttempts: 1)

        guard case .retry(let delay) = result else {
            return XCTFail("Expected .retry, got \(result)")
        }
        XCTAssertEqual(delay, 0.01, accuracy: 0.0001)
    }

    func testHandleError_migrationError_returnsMigrationRecovery() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSMigrationError)

        let result = sut.handleError(error, currentAttempts: 0)

        guard case .migrationRecovery = result else {
            return XCTFail("Expected .migrationRecovery, got \(result)")
        }
    }

    func testHandleError_unrecoverable_returnsStoreReset() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSValidationMissingMandatoryPropertyError)

        let result = sut.handleError(error, currentAttempts: 0)

        guard case .storeReset = result else {
            return XCTFail("Expected .storeReset, got \(result)")
        }
    }

    func testHandleError_attemptsExhausted_returnsStoreReset() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreTimeoutError)

        let result = sut.handleError(error, currentAttempts: 3)

        guard case .storeReset = result else {
            return XCTFail("Expected .storeReset when attempts exhausted, got \(result)")
        }
    }

    // MARK: - prepareMigrationRecovery

    func testPrepareMigrationRecovery_validStore_createsBackupAndRemovesStore() {
        let succeeded = sut.prepareMigrationRecovery(for: storeURL)

        XCTAssertTrue(succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path),
                       "Store should be removed after migration recovery prep")
        let backups = CoreDataBackupManager.listBackups(for: storeURL)
        XCTAssertEqual(backups.count, 1, "Exactly one backup should have been created")
    }

    func testPrepareMigrationRecovery_missingStore_returnsFalse() {
        let missing = tempDir.appendingPathComponent("missing.sqlite")
        XCTAssertFalse(sut.prepareMigrationRecovery(for: missing))
    }

    // MARK: - prepareStoreReset

    func testPrepareStoreReset_validStore_createsBackupAndRemovesStore() {
        let succeeded = sut.prepareStoreReset(for: storeURL)

        XCTAssertTrue(succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
        let backups = CoreDataBackupManager.listBackups(for: storeURL)
        XCTAssertEqual(backups.count, 1)
    }

    func testPrepareStoreReset_missingStore_returnsFalse() {
        let missing = tempDir.appendingPathComponent("missing.sqlite")
        XCTAssertFalse(sut.prepareStoreReset(for: missing))
    }

    // MARK: - notifyUserOfCriticalError

    func testNotifyUserOfCriticalError_postsNotificationWithWrappedError() {
        let expectation = self.expectation(description: "criticalErrorNotification")
        let underlying = NSError(domain: "TestDomain", code: 42)

        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CoreDataCriticalError"),
            object: nil,
            queue: .main
        ) { notification in
            if let error = notification.userInfo?["error"] as? CoreDataError,
               case .persistentFailure = error {
                expectation.fulfill()
            }
        }

        sut.notifyUserOfCriticalError(underlying)

        wait(for: [expectation], timeout: 2.0)
        NotificationCenter.default.removeObserver(observer)
    }
}
