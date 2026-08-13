import Foundation

/// Identifies one account transition so an older, superseded transition cannot
/// reopen outbound admission after a newer sign-out or account switch closed it.
struct OutboundAccountTransition: Equatable, Sendable {
    fileprivate let generation: UInt64
}

/// Admission held from the start of outbound preparation until the background
/// send and its local reconciliation have fully unwound.
struct OutboundSendReservation: Equatable, Sendable {
    fileprivate let id: UUID
}

/// How `OutboundTaskRegistry.reopenAdmission(after:)` resolved.
///
/// The two refusal causes are not interchangeable: supersession means a newer
/// transition owns the account boundary (including its own credential
/// cleanup), while undrained sends mean this transition is still the owner and
/// admission is merely latched closed until the leaked work unwinds.
enum OutboundAdmissionReopenResult: Equatable, Sendable {
    /// This transition is the most recent one and every earlier send has
    /// drained; admission is open again.
    case reopened
    /// A newer transition closed admission after this one. That transition
    /// owns the boundary now; the caller must unwind without reopening.
    case supersededByNewerTransition
    /// This transition is still the most recent one, but at least one send
    /// reservation has not drained. Admission stays closed until that work
    /// unwinds; no newer transition exists to own the refusal.
    case undrainedSends
}

/// Account-scoped boundary for outbound sends.
///
/// This stays independent of `SyncRunCoordinator`: sending and syncing may run
/// concurrently during normal use, while account transitions can still close
/// admission, cancel preparation, and await all old-account writers. Once the
/// durable Gmail-admission marker is persisted, the send is drained rather than
/// cancelled because its remote commit state can become ambiguous.
@MainActor
final class OutboundTaskRegistry {
    static let shared = OutboundTaskRegistry()

    private enum TransmissionPhase: Equatable {
        case preflight
        case persistingAdmission
        case admitted
    }

    private struct Entry {
        var isCancelled = false
        var transmissionPhase = TransmissionPhase.preflight
        var cancelBeforeTransmission: (() -> Void)?
        var backgroundTask: Task<Void, Never>?
    }

    private var acceptsNewSends: Bool
    private var transitionGeneration: UInt64 = 0
    private var entries: [UUID: Entry] = [:]
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(admissionOpen: Bool = false) {
        acceptsNewSends = admissionOpen
    }

    /// Closes admission synchronously. AuthSession calls this before its first
    /// suspension point so no send can slip in while quiescence is being acquired.
    @discardableResult
    func closeAdmission() -> OutboundAccountTransition {
        transitionGeneration &+= 1
        acceptsNewSends = false

        for id in Array(entries.keys) {
            guard var entry = entries[id] else { continue }
            entry.isCancelled = true
            if entry.transmissionPhase == .preflight {
                entry.cancelBeforeTransmission?()
            }
            entries[id] = entry
        }

        return OutboundAccountTransition(generation: transitionGeneration)
    }

    /// Reopens only for the most recent transition, after every earlier send
    /// has drained. A queued newer transition therefore cannot be undone by an
    /// older sign-in finishing later.
    @discardableResult
    func reopenAdmission(after transition: OutboundAccountTransition) -> OutboundAdmissionReopenResult {
        // Supersession is checked first on purpose. When a stale transition
        // also finds undrained entries, the newer transition owns the boundary
        // and the drain; reporting a latch instead would route a launch
        // restore into discarding credentials whose cleanup the queued
        // sign-out already owns.
        guard transition.generation == transitionGeneration else {
            return .supersededByNewerTransition
        }
        guard entries.isEmpty else {
            return .undrainedSends
        }

        acceptsNewSends = true
        return .reopened
    }

    func reserve() -> OutboundSendReservation? {
        guard acceptsNewSends else { return nil }

        let reservation = OutboundSendReservation(id: UUID())
        entries[reservation.id] = Entry()
        return reservation
    }

    func isActive(_ reservation: OutboundSendReservation) -> Bool {
        guard acceptsNewSends,
              let entry = entries[reservation.id] else {
            return false
        }
        return !entry.isCancelled
    }

    /// Registers the actual task performing pre-handoff work so account
    /// teardown can deliver cooperative cancellation instead of only
    /// invalidating the reservation. The reservation remains the drain owner.
    @discardableResult
    func ownPreparation<Success>(
        _ task: Task<Success, Error>,
        for reservation: OutboundSendReservation
    ) -> Bool {
        guard var entry = entries[reservation.id] else {
            task.cancel()
            return false
        }

        entry.cancelBeforeTransmission = { task.cancel() }
        entries[reservation.id] = entry

        let remainsActive = acceptsNewSends && !entry.isCancelled
        if !remainsActive {
            task.cancel()
        }
        return remainsActive
    }

    /// Atomically transfers an existing reservation to background preflight.
    /// Even a cancelled reservation adopts and awaits the task, closing the
    /// prep-to-background handoff gap before destructive store cleanup. The
    /// inner send worker remains cancellable until `admitTransmission` persists
    /// the remote-admission marker and switches this entry to drain-only.
    @discardableResult
    func handOff(
        _ reservation: OutboundSendReservation,
        to backgroundTask: Task<Void, Never>,
        cancelBeforeTransmission: (() -> Void)? = nil
    ) -> Bool {
        var entry = entries[reservation.id] ?? Entry(isCancelled: true)
        if entry.transmissionPhase == .preflight {
            entry.cancelBeforeTransmission = cancelBeforeTransmission
        }
        entry.backgroundTask = backgroundTask
        entries[reservation.id] = entry

        let remainsActive = acceptsNewSends && !entry.isCancelled
        if !remainsActive, entry.transmissionPhase == .preflight {
            entry.cancelBeforeTransmission?()
        }
        Task { @MainActor [weak self] in
            await backgroundTask.value
            self?.finish(reservation)
        }
        return remainsActive
    }

    /// Performs the final Gmail admission decision without yielding the main
    /// actor. Marker persistence must succeed before account teardown stops
    /// cancelling this send; after that point the background task is drain-only.
    func admitTransmission(
        _ reservation: OutboundSendReservation,
        persistingMarker persistMarker: () throws -> Void
    ) throws {
        guard acceptsNewSends,
              var entry = entries[reservation.id],
              !entry.isCancelled,
              entry.transmissionPhase == .preflight else {
            throw CancellationError()
        }

        // A synchronous Core Data observer can reenter `closeAdmission` during
        // the save. Defer cancellation until the save establishes whether this
        // send crossed the durable admission boundary.
        entry.transmissionPhase = .persistingAdmission
        entries[reservation.id] = entry

        do {
            try persistMarker()
        } catch {
            if var currentEntry = entries[reservation.id] {
                currentEntry.transmissionPhase = .preflight
                entries[reservation.id] = currentEntry
                if currentEntry.isCancelled || !acceptsNewSends {
                    currentEntry.cancelBeforeTransmission?()
                }
            }
            throw error
        }

        // Marker persistence is the linearization point. Even if admission was
        // closed reentrantly during the save, this send is now drain-only.
        if var currentEntry = entries[reservation.id] {
            currentEntry.transmissionPhase = .admitted
            currentEntry.cancelBeforeTransmission = nil
            entries[reservation.id] = currentEntry
        }
    }

    /// Releases a reservation whose preparation failed or was invalidated
    /// before ownership moved to a background task.
    func finish(_ reservation: OutboundSendReservation) {
        entries.removeValue(forKey: reservation.id)
        resumeDrainWaitersIfNeeded()
    }

    /// Cancels admitted preparation and waits for preparation reservations and
    /// background sends alike. Callers close admission before invoking this.
    func cancelAndAwaitAll() async {
        for id in Array(entries.keys) {
            guard var entry = entries[id] else { continue }
            entry.isCancelled = true
            if entry.transmissionPhase == .preflight {
                entry.cancelBeforeTransmission?()
            }
            entries[id] = entry
        }

        guard !entries.isEmpty else { return }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }

    private func resumeDrainWaitersIfNeeded() {
        guard entries.isEmpty, !drainWaiters.isEmpty else { return }

        let waiters = drainWaiters
        drainWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}
