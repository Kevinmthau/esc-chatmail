import Foundation
import os

/// Ensures a background task's completion callback runs exactly once, whether
/// triggered by normal completion, the expiration handler, or owner
/// deallocation — whichever fires first wins; later calls are ignored.
final class BackgroundTaskCompletionLatch: @unchecked Sendable {
    private let completed = OSAllocatedUnfairLock(initialState: false)
    private let onComplete: (Bool) -> Void

    init(onComplete: @escaping (Bool) -> Void) {
        self.onComplete = onComplete
    }

    func complete(success: Bool) {
        let alreadyCompleted = completed.withLock { done -> Bool in
            if done { return true }
            done = true
            return false
        }
        guard !alreadyCompleted else { return }
        onComplete(success)
    }
}
