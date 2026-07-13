import XCTest
import CoreData
@testable import esc_chatmail

/// Regression tests for cancellation handling in `saveContextWithRetry`'s
/// backoff loop: a task cancelled mid-backoff must stop retrying instead of
/// burning the remaining attempts with zero delay (the old
/// `try? await Task.sleep` swallowed `CancellationError`).
final class CoreDataBatchOperationsRetryTests: XCTestCase {

    /// A store-less context whose `save()` throws a scripted error, driving
    /// `saveContextWithRetry` down its backoff paths deterministically without
    /// touching a persistent store.
    private final class ScriptedSaveContext: NSManagedObjectContext, @unchecked Sendable {
        private let lock = NSLock()
        private var _saveAttempts = 0
        private let scriptedError: NSError
        private let failuresBeforeSuccess: Int
        var onSaveAttempt: (@Sendable (Int) -> Void)?

        init(error: NSError, failuresBeforeSuccess: Int = .max) {
            self.scriptedError = error
            self.failuresBeforeSuccess = failuresBeforeSuccess
            super.init(concurrencyType: .privateQueueConcurrencyType)
        }

        required init?(coder: NSCoder) {
            fatalError("not supported in tests")
        }

        var saveAttempts: Int {
            lock.lock()
            defer { lock.unlock() }
            return _saveAttempts
        }

        override func save() throws {
            lock.lock()
            _saveAttempts += 1
            let attempt = _saveAttempts
            lock.unlock()

            onSaveAttempt?(attempt)
            if attempt <= failuresBeforeSuccess {
                throw scriptedError
            }
        }
    }

    /// Retryable error that takes the standard 100ms-base backoff path
    /// (not constraint-merge, not multi-validation, not SQLite-busy).
    private static let standardRetryableError = NSError(
        domain: "CoreDataBatchOperationsRetryTests",
        code: 9_999
    )

    /// Takes the SQLite-busy 500ms-base backoff path.
    private static let sqliteBusyError = NSError(domain: NSSQLiteErrorDomain, code: 5)

    private func assertCancellationDuringBackoffStopsRetries(
        error: NSError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // High enough that reaching the final attempt despite cancellation
        // would need many seconds of cumulative scheduling delay, keeping the
        // "loop stopped early" assertion robust on loaded CI machines.
        let maxRetries = 8
        let context = ScriptedSaveContext(error: error)
        let operations = CoreDataBatchOperations()

        let firstAttempt = expectation(description: "first save attempt ran")
        context.onSaveAttempt = { attempt in
            if attempt == 1 { firstAttempt.fulfill() }
        }

        let saveTask = Task {
            try await operations.saveContextWithRetry(context, maxRetries: maxRetries)
        }

        await fulfillment(of: [firstAttempt], timeout: 10.0)
        // Lands just before or inside the first backoff sleep; either way the
        // sleep must report cancellation instead of returning immediately.
        saveTask.cancel()

        switch await saveTask.result {
        case .success:
            XCTFail("Expected saveContextWithRetry to throw after cancellation", file: file, line: line)
        case .failure(let thrown):
            XCTAssertTrue(
                thrown is CancellationError,
                "Expected CancellationError, got \(thrown)",
                file: file,
                line: line
            )
        }
        XCTAssertLessThan(
            context.saveAttempts,
            maxRetries,
            "Cancelled backoff must stop the retry loop, not hammer the remaining retries with zero delay",
            file: file,
            line: line
        )
    }

    func testCancellationDuringStandardBackoffStopsRetries() async {
        await assertCancellationDuringBackoffStopsRetries(error: Self.standardRetryableError)
    }

    func testCancellationDuringSQLiteBusyBackoffStopsRetries() async {
        await assertCancellationDuringBackoffStopsRetries(error: Self.sqliteBusyError)
    }

    func testUncancelledTaskExhaustsRetriesAndThrowsSaveFailure() async {
        let context = ScriptedSaveContext(error: Self.standardRetryableError)
        let operations = CoreDataBatchOperations()

        do {
            try await operations.saveContextWithRetry(context, maxRetries: 2)
            XCTFail("Expected contextSaveFailure after exhausting retries")
        } catch is CancellationError {
            XCTFail("Uncancelled task must not throw CancellationError")
        } catch {
            XCTAssertTrue(error is BatchOperationError, "Expected BatchOperationError, got \(error)")
        }
        XCTAssertEqual(context.saveAttempts, 2)
    }

    func testUncancelledTaskRecoversWhenTransientFailureClears() async throws {
        let context = ScriptedSaveContext(error: Self.standardRetryableError, failuresBeforeSuccess: 1)
        let operations = CoreDataBatchOperations()

        try await operations.saveContextWithRetry(context, maxRetries: 3)

        XCTAssertEqual(context.saveAttempts, 2)
    }
}
