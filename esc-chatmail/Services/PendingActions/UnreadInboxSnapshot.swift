import Foundation
import CoreData

/// The unread INBOX messages a chat had when it opened, from a fetch that
/// was already queued when this value was handed out
/// (`MessageActions.startUnreadInboxSnapshot`).
///
/// The caller holds the value from the turn the chat opens and awaits the
/// IDs later, in its own task. What the fetch sees is fixed by when it was
/// queued, not by when anyone asks for the result.
///
/// `@unchecked Sendable`: `result` and `waiters` are guarded by `lock`.
final class UnreadInboxSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var result: [NSManagedObjectID]?
    private var waiters: [CheckedContinuation<[NSManagedObjectID], Never>] = []

    init() {}

    /// A snapshot that needed no fetch.
    init(messageIDs: [NSManagedObjectID]) {
        result = messageIDs
    }

    /// Whether the fetch has finished. A test reads it to learn that the
    /// fetch ran without the main actor's help.
    var isFulfilled: Bool {
        lock.withLock { result != nil }
    }

    /// The message IDs, once the fetch has finished.
    var messageIDs: [NSManagedObjectID] {
        get async {
            await withCheckedContinuation { continuation in
                let finished: [NSManagedObjectID]? = lock.withLock {
                    if result == nil {
                        waiters.append(continuation)
                    }
                    return result
                }
                if let finished {
                    continuation.resume(returning: finished)
                }
            }
        }
    }

    /// Delivers the fetch's result. Only the first call counts.
    func fulfill(_ messageIDs: [NSManagedObjectID]) {
        let waiting: [CheckedContinuation<[NSManagedObjectID], Never>] = lock.withLock {
            guard result == nil else { return [] }
            result = messageIDs
            let waiting = waiters
            waiters = []
            return waiting
        }
        waiting.forEach { $0.resume(returning: messageIDs) }
    }
}
