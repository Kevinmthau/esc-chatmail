import Foundation
@testable import esc_chatmail

/// Controllable `ForegroundSyncPerforming` for tests. Promoted verbatim from
/// `ForegroundSyncCoordinatorTests`, where it was private, so the
/// conversation-list launch repair suites can inject a sync-idle wait
/// instead of awaiting the shared `SyncEngine`.
///
/// By default `waitForCurrentSyncToComplete()` returns immediately; set
/// `onWaitForCurrentSyncToComplete` to gate it.
@MainActor
final class MockForegroundSyncEngine: ForegroundSyncPerforming {
    private typealias Completion = @MainActor @Sendable (Bool) -> Bool

    var requestResults: [ForegroundSyncRequestResult] = [.started]
    var onWaitForCurrentSyncToComplete: (() async -> Void)?
    var onTriggerIncrementalSyncIfPossible: (() async -> ForegroundSyncRequestResult)?
    private var completions: [Completion] = []
    private(set) var waitForCurrentSyncToCompleteCalls = 0
    private(set) var triggerIncrementalSyncIfPossibleCalls = 0

    func waitForCurrentSyncToComplete() async {
        waitForCurrentSyncToCompleteCalls += 1
        if let onWaitForCurrentSyncToComplete {
            await onWaitForCurrentSyncToComplete()
        }
    }

    func triggerIncrementalSyncIfPossible(
        completion: @escaping @MainActor @Sendable (Bool) -> Bool
    ) async -> ForegroundSyncRequestResult {
        triggerIncrementalSyncIfPossibleCalls += 1
        completions.append(completion)
        if let onTriggerIncrementalSyncIfPossible {
            return await onTriggerIncrementalSyncIfPossible()
        }

        if !requestResults.isEmpty {
            return requestResults.removeFirst()
        }

        return .started
    }

    /// - Returns: what the completion answered: whether the coordinator
    ///   queued a continuation to run at once.
    @discardableResult
    func completeRequest(at index: Int, hasDurableContinuation: Bool) -> Bool {
        completions[index](hasDurableContinuation)
    }
}
