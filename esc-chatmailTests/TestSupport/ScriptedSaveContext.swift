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
    private let failingFromAttempt: Int?
    var onSaveAttempt: (@Sendable (Int) -> Void)?

    init(error: NSError, failuresBeforeSuccess: Int = .max) {
        self.scriptedError = error
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.failingFromAttempt = nil
        super.init(concurrencyType: .privateQueueConcurrencyType)
    }

    /// Succeeds attempts below `failingFromAttempt`, fails that attempt and
    /// every later one — the inverse of `failuresBeforeSuccess`, for runs
    /// whose EARLY saves must land durably (per-page recovery saves) while a
    /// LATER save (the final commit-carrying one) fails.
    init(error: NSError, failingFromAttempt: Int) {
        self.scriptedError = error
        self.failuresBeforeSuccess = 0
        self.failingFromAttempt = failingFromAttempt
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
        if let failingFromAttempt {
            if attempt >= failingFromAttempt {
                throw scriptedError
            }
            try super.save()
            return
        }
        if attempt <= failuresBeforeSuccess {
            throw scriptedError
        }
    }
}
