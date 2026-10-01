import Foundation

/// Keeps first transmissions within one conversation in tap order.
///
/// The chat composer releases at optimistic persistence, so a second reply can
/// enter preflight while the first is still building MIME or uploading. Gmail
/// stamps `internalDate` when it accepts a message and the transcript sorts by
/// it, so a short reply that reached Gmail before a long earlier one swapped
/// places when the echoes landed, and recipients got them out of order.
///
/// Each send therefore waits, strictly before its transmission barrier, until
/// every earlier send in the same conversation is terminal: succeeded, failed,
/// ambiguous or cancelled. Any terminal predecessor releases the next send;
/// this type never retransmits anything.
///
/// The wait is cancellation-aware. A waiting send is still a preflight
/// `OutboundTaskRegistry` entry, so `closeAdmission` cancels its worker and
/// the wait throws `CancellationError` at once instead of waiting out the
/// predecessor's network round trip. Callers re-check registry activity after
/// the wait (`OutboundTaskRegistry.admitTransmission` does, inside the
/// barrier).
@MainActor
final class OutboundConversationSendSequencer {
    static let shared = OutboundConversationSendSequencer()

    /// One send's place in its conversation's queue. `finish()` is idempotent
    /// and must run on every path, or later sends in that conversation wait
    /// until they are cancelled.
    struct Turn: Sendable {
        fileprivate let id: UUID
        fileprivate let conversation: ConversationReference
        fileprivate let sequencer: OutboundConversationSendSequencer

        /// Returns once every earlier turn in this conversation has finished.
        func waitUntilFront() async throws {
            try await sequencer.waitUntilFront(self)
        }

        func finish() async {
            await sequencer.finish(self)
        }
    }

    private var queues: [ConversationReference: [UUID]] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    /// Turns currently suspended in `waitUntilFront`. Lets tests observe that
    /// a send is parked behind its predecessor rather than merely slow.
    var suspendedTurnCount: Int {
        waiters.count
    }

    /// Appends a turn synchronously, so enqueue order is the main-actor order
    /// in which optimistic messages were created, which is tap order.
    func enqueue(conversation: ConversationReference) -> Turn {
        let turn = Turn(id: UUID(), conversation: conversation, sequencer: self)
        queues[conversation, default: []].append(turn.id)
        return turn
    }

    func waitUntilFront(_ turn: Turn) async throws {
        try Task.checkCancellation()
        guard !isFront(turn) else { return }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // The cancellation handler hops to the main actor, so it can
                // run before this registration; check again here.
                if Task.isCancelled || !isQueued(turn) {
                    continuation.resume(throwing: CancellationError())
                } else if isFront(turn) {
                    continuation.resume()
                } else {
                    waiters[turn.id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [self] in
                self.cancelWait(turn)
            }
        }
    }

    func finish(_ turn: Turn) {
        guard var queue = queues[turn.conversation],
              let index = queue.firstIndex(of: turn.id) else { return }
        queue.remove(at: index)
        // A turn that finishes while still waiting (its send failed some
        // other way) must not leave a continuation behind.
        waiters.removeValue(forKey: turn.id)?.resume(throwing: CancellationError())

        guard let newFront = queue.first else {
            queues[turn.conversation] = nil
            return
        }
        queues[turn.conversation] = queue
        if index == 0 {
            waiters.removeValue(forKey: newFront)?.resume()
        }
    }

    private func cancelWait(_ turn: Turn) {
        waiters.removeValue(forKey: turn.id)?.resume(throwing: CancellationError())
    }

    private func isFront(_ turn: Turn) -> Bool {
        queues[turn.conversation]?.first == turn.id
    }

    private func isQueued(_ turn: Turn) -> Bool {
        queues[turn.conversation]?.contains(turn.id) == true
    }
}
