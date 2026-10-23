import Foundation
import Combine

/// Feeds the conversation list's banner for pending actions the queue gave up
/// on (`status == "abandoned"`). Before it, nothing observed
/// `.pendingActionFailed` and nothing called the abandoned-action APIs: an
/// archive or Report Spam that Gmail rejected looked done in the app while
/// the mail stayed in the Gmail inbox, with nothing but a log line to say so.
@MainActor
final class AbandonedPendingActionsModel: ObservableObject {
    @Published private(set) var summary: AbandonedPendingActionsPolicy.Summary?

    private let manager: any AbandonedPendingActionsManaging
    /// Bumped by every read and mutation; a read publishes only if it is
    /// still the latest, so a stale read never brings the banner back.
    /// Deliberately not task cancellation: cancelling a retry's task would
    /// make its run acquisition bail before resetting anything.
    private var readGeneration: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()

    /// - Parameter notificationCenter: Source of `.pendingActionFailed` (an
    ///   action was just abandoned) and `.syncCompleted` (a periodic recheck).
    init(
        manager: any AbandonedPendingActionsManaging,
        notificationCenter: NotificationCenter = .default
    ) {
        self.manager = manager
        notificationCenter.publisher(for: .pendingActionFailed)
            .merge(with: notificationCenter.publisher(for: .syncCompleted))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    func refresh() {
        readGeneration &+= 1
        let generation = readGeneration
        let manager = self.manager
        Task { [weak self] in
            let actions = await manager.fetchAbandonedActions()
            self?.publish(actions, readGeneration: generation)
        }
    }

    func retryAll() {
        perform { manager in
            await manager.retryAllAbandonedActions()
        }
    }

    func dismissAll() {
        perform { manager in
            await manager.dismissAllAbandonedActions()
        }
    }

    /// Hides the banner at once, then re-reads after the mutation: a retry
    /// that fails again brings it back.
    private func perform(
        _ mutation: @escaping @Sendable (any AbandonedPendingActionsManaging) async -> Void
    ) {
        readGeneration &+= 1
        summary = nil
        let manager = self.manager
        Task { [weak self] in
            await mutation(manager)
            self?.refresh()
        }
    }

    private func publish(_ actions: [AbandonedActionInfo], readGeneration generation: UInt64) {
        guard generation == readGeneration else { return }
        summary = AbandonedPendingActionsPolicy.summary(
            forActionDescriptions: actions.map(\.actionDescription)
        )
    }
}
