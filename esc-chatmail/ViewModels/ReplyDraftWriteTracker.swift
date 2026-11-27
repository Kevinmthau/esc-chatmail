import Foundation

/// Counts the reply-draft writes that are waiting for the cleanup-sensitive
/// gate or running inside it, so that quitting the Mac app can wait for them
/// the way it waits for sends (`AppTerminationWait`).
///
/// A write is counted from the turn that schedules it until its task
/// returns, whether it saved, found nothing of its own to write, failed or
/// was cancelled by a newer request: `ChatViewModel.startReplyDraftSave`,
/// which every scheduled draft save goes through, and the merge of an unsent
/// reply into the stored draft (`ChatViewModel.handOffUnsentReply`). A
/// composer's change the 350 ms debounce has not handed to a save yet is not
/// a write; the quit makes that save first
/// (`ChatReplyComposerDirectory.flushPresentedDraftsForTermination`).
///
/// It only counts and waits. Nothing here writes a draft, takes the gate or
/// touches a send.
@MainActor
final class ReplyDraftWriteTracker {
    /// One counted write. `end()` is idempotent.
    @MainActor
    final class Write {
        private let tracker: ReplyDraftWriteTracker
        private var hasEnded = false

        fileprivate init(tracker: ReplyDraftWriteTracker) {
            self.tracker = tracker
        }

        func end() {
            guard !hasEnded else { return }
            hasEnded = true
            tracker.endWrite()
        }
    }

    /// Internal (not private) only so tests can count what a request added.
    private(set) var outstandingWriteCount = 0
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Counts a write from now. The caller ends it when the write's task
    /// returns, on every path.
    func beginWrite() -> Write {
        outstandingWriteCount += 1
        return Write(tracker: self)
    }

    var hasOutstandingWrites: Bool {
        outstandingWriteCount > 0
    }

    /// Waits until no write is outstanding, without touching any of them.
    /// Returns early when the calling task is cancelled, which is how the
    /// quit's deadline ends the wait (`AppTerminationWait`). Modelled on
    /// `OutboundTaskRegistry.waitUntilOutstandingSendsFinish()`.
    func waitUntilIdle() async {
        guard hasOutstandingWrites else { return }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Runs synchronously on the main actor, so a cancellation hop
                // below can only arrive after this has installed the waiter.
                if !hasOutstandingWrites || Task.isCancelled {
                    continuation.resume()
                } else {
                    idleWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.idleWaiters.removeValue(forKey: waiterID)?.resume()
            }
        }
    }

    /// Internal (not private) only so tests can tell when a
    /// `waitUntilIdle()` caller is actually waiting.
    var idleWaiterCount: Int {
        idleWaiters.count
    }

    fileprivate func endWrite() {
        guard outstandingWriteCount > 0 else { return }
        outstandingWriteCount -= 1
        guard outstandingWriteCount == 0 else { return }

        let waiters = Array(idleWaiters.values)
        idleWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}
