import XCTest
import CoreData
@testable import esc_chatmail

final class CoreDataStackWaitTests: XCTestCase {

    func testWaitForStoreToLoad_failsImmediatelyWhenLoadErrorIsStored() async {
        let stack = CoreDataStack()
        let underlying = NSError(
            domain: "CoreDataStackWaitTests",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "stored load failure"]
        )
        stack.debugSetStoreLoadErrorForTesting(underlying)

        let start = Date()

        do {
            try await stack.waitForStoreToLoad(timeout: 1.0)
            XCTFail("Expected waitForStoreToLoad to throw")
        } catch CoreDataError.storeLoadFailed(let error) {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, underlying.domain)
            XCTAssertEqual(nsError.code, underlying.code)
        } catch {
            XCTFail("Expected storeLoadFailed, got \(error)")
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.5,
            "Stored load errors should fail waiters immediately instead of waiting for timeout"
        )
    }

    /// The container is lazy and loads once per process, so a latched load
    /// failure used to last until the app was killed: launch retried every
    /// second against the same latched error and never reopened the store.
    ///
    /// Revert-check: making `CoreDataStack.retryLoadAfterFailure` return
    /// without calling `loadPersistentStores` fails the final wait.
    func testRetryLoadAfterFailure_reloadsOnceTheStoreCanBeOpened() async throws {
        // A regular file where the store's directory belongs makes the first
        // open fail without anything that looks like a corrupt database.
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestCoreDataStack-retry-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: storeDirectory)
        let container = TestCoreDataStack.makeUnloadedSQLiteContainer(
            storeURL: storeDirectory.appendingPathComponent("Mailbox.sqlite")
        )
        let stack = CoreDataStack(unloadedPersistentContainerForTesting: container)
        _ = stack.persistentContainer

        do {
            try await stack.waitForStoreToLoad(timeout: 5)
            return XCTFail("Expected the first load to fail")
        } catch CoreDataError.storeLoadFailed(let error) {
            XCTAssertTrue(error is PersistentStoreLoadError, "Expected a typed load error, got \(error)")
        }

        try FileManager.default.removeItem(at: storeDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        stack.retryLoadAfterFailure()

        try await stack.waitForStoreToLoad(timeout: 5)
        XCTAssertEqual(container.persistentStoreCoordinator.persistentStores.count, 1)
    }

    /// Without a latched failure there is nothing to retry: a second load
    /// of an attached store would fail and latch an error of its own.
    func testRetryLoadAfterFailure_isNoOpWhileStoreIsLoaded() async throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestCoreDataStack-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let container = TestCoreDataStack.makeUnloadedSQLiteContainer(
            storeURL: storeDirectory.appendingPathComponent("Mailbox.sqlite")
        )
        let stack = CoreDataStack(unloadedPersistentContainerForTesting: container)
        _ = stack.persistentContainer
        try await stack.waitForStoreToLoad(timeout: 5)

        stack.retryLoadAfterFailure()

        try await stack.waitForStoreToLoad(timeout: 5)
        XCTAssertEqual(container.persistentStoreCoordinator.persistentStores.count, 1)
    }
}
