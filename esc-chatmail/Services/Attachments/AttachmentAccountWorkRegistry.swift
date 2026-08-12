import Foundation

/// Identifies the account-work admission generation observed by a synchronous
/// producer before it hands work to an asynchronous task. A token from an older
/// account remains invalid after admission reopens.
struct AttachmentAccountWorkAdmissionToken: Equatable, Sendable {
    fileprivate let generation: UInt64
}

/// Cancellation generation shared by account-scoped attachment file work that
/// lives outside `AttachmentDownloader` (for example Photos/UI document imports).
final class AttachmentAccountWorkGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isActive: Bool {
        lock.withLock { !cancelled && !Task.isCancelled }
    }

    fileprivate func cancel() {
        lock.withLock { cancelled = true }
    }
}

/// Account-transition boundary for local attachment writers that are not owned
/// by the downloader. Operations register before starting so sign-out can close
/// admission, cancel them, and await complete unwinding before deleting files or
/// resetting Core Data.
final class AttachmentAccountWorkRegistry: @unchecked Sendable {
    static let shared = AttachmentAccountWorkRegistry()

    private struct Operation {
        let generation: AttachmentAccountWorkGeneration
        let task: Task<Void, Never>
    }

    private let lock = NSLock()
    private var acceptsNewWork: Bool
    private var admissionGeneration: UInt64 = 0
    private var operations: [UUID: Operation] = [:]

    init(admissionOpen: Bool = true) {
        acceptsNewWork = admissionOpen
    }

    /// Captures admission synchronously on the producer's executor. Delayed
    /// handoffs must present this token when they eventually register work.
    func captureAdmissionToken() -> AttachmentAccountWorkAdmissionToken? {
        lock.withLock {
            guard acceptsNewWork else { return nil }
            return AttachmentAccountWorkAdmissionToken(generation: admissionGeneration)
        }
    }

    var activeOperationCount: Int {
        lock.withLock { operations.count }
    }

    @discardableResult
    @MainActor
    func startOperation(
        _ body: @escaping @MainActor (AttachmentAccountWorkGeneration) async -> Void
    ) -> Task<Void, Never>? {
        lock.withLock {
            guard acceptsNewWork, !Task.isCancelled else { return nil }

            let id = UUID()
            let generation = AttachmentAccountWorkGeneration()
            let task = Task { @MainActor [self] in
                defer { self.finishOperation(id) }
                await body(generation)
            }
            operations[id] = Operation(generation: generation, task: task)
            return task
        }
    }

    /// Registers account-scoped file work that must not inherit MainActor.
    /// The task remains owned by this registry so teardown can cancel and drain
    /// every write before account files and Core Data are reset.
    @discardableResult
    func startDetachedOperation(
        priority: TaskPriority? = .userInitiated,
        _ body: @escaping @Sendable (AttachmentAccountWorkGeneration) async -> Void
    ) -> Task<Void, Never>? {
        startDetachedOperation(
            expectedAdmission: nil,
            priority: priority,
            body
        )
    }

    /// Registers a delayed handoff only if the account admission captured by
    /// its producer is still current. Closing and reopening admission advances
    /// the generation, so old save callbacks cannot become new-account work.
    @discardableResult
    func startDetachedOperation(
        for admission: AttachmentAccountWorkAdmissionToken,
        priority: TaskPriority? = .userInitiated,
        _ body: @escaping @Sendable (AttachmentAccountWorkGeneration) async -> Void
    ) -> Task<Void, Never>? {
        startDetachedOperation(
            expectedAdmission: admission,
            priority: priority,
            body
        )
    }

    private func startDetachedOperation(
        expectedAdmission: AttachmentAccountWorkAdmissionToken?,
        priority: TaskPriority?,
        _ body: @escaping @Sendable (AttachmentAccountWorkGeneration) async -> Void
    ) -> Task<Void, Never>? {
        lock.withLock {
            guard acceptsNewWork,
                  !Task.isCancelled,
                  expectedAdmission.map({ $0.generation == admissionGeneration }) ?? true else {
                return nil
            }

            let id = UUID()
            let generation = AttachmentAccountWorkGeneration()
            let task = Task.detached(priority: priority) { [self] in
                defer { self.finishOperation(id) }
                await body(generation)
            }
            operations[id] = Operation(generation: generation, task: task)
            return task
        }
    }

    private func finishOperation(_ id: UUID) {
        _ = lock.withLock { operations.removeValue(forKey: id) }
    }

    func cancelAndAwaitAll() async {
        let activeOperations = lock.withLock {
            acceptsNewWork = false
            admissionGeneration &+= 1
            return Array(operations.values)
        }

        activeOperations.forEach {
            $0.generation.cancel()
            $0.task.cancel()
        }
        for operation in activeOperations {
            await operation.task.value
        }
    }

    /// Returns false when a leaked operation from the closed account is still
    /// outstanding. This transition's reopen has failed, so the caller must fail
    /// the account reopen instead of discarding this; a later transition can
    /// still reopen once the outstanding operation unwinds.
    func reopenAdmission() -> Bool {
        let didReopen = lock.withLock {
            guard operations.isEmpty else { return false }
            admissionGeneration &+= 1
            acceptsNewWork = true
            return true
        }
        if !didReopen {
            // Logged outside the lock so a future logging hook cannot re-enter.
            Log.error(
                "Refusing to reopen attachment account work while operations from the closed account remain",
                category: .attachment
            )
        }
        return didReopen
    }
}
