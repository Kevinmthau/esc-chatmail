import Foundation
import CoreData

/// A store-less context whose `save()` throws a scripted error, driving
/// save-retry paths deterministically without touching a persistent store.
/// Shared across suites (originally private to `CoreDataBatchOperationsRetryTests`).
final class ScriptedSaveContext: NSManagedObjectContext, @unchecked Sendable {
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
