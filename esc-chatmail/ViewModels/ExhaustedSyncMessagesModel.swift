import Foundation
import Combine

/// Feeds the conversation list's banner for mail sync gave up on
/// (`ExhaustedSyncMessagesPolicy`). Before it, nothing observed
/// `.syncMessagesAbandoned`, and a message the drain could not download in
/// five tries was deleted from the ledger with only a log line
/// (architecture review 2026-11, sync-persist-path#6).
@MainActor
final class ExhaustedSyncMessagesModel: ObservableObject {
    @Published private(set) var summary: ExhaustedSyncMessagesPolicy.Summary?

    private let manager: any ExhaustedSyncMessagesManaging
    private let accountEmail: @MainActor () -> String?
    private let requestSync: @MainActor () -> Void
    /// Bumped by every read and mutation; a read publishes only if it is still
    /// the latest, so a stale read never brings the banner back.
    private var readGeneration: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()

    /// - Parameters:
    ///   - accountEmail: The signed-in address, for Open in Gmail's link.
    ///   - requestSync: Asked for once Retry gave rows back, so the drain
    ///     tries them now rather than at the next periodic sync. Called after
    ///     the account-work lease is released, never inside it.
    ///   - notificationCenter: Source of `.syncCompleted` (every sync's save,
    ///     the drain's verdicts included) and `.syncMessagesAbandoned` (the
    ///     escape hatch abandoned IDs, which can bring back a row the drain
    ///     had given up on).
    init(
        manager: any ExhaustedSyncMessagesManaging,
        accountEmail: @escaping @MainActor () -> String?,
        requestSync: @escaping @MainActor () -> Void,
        notificationCenter: NotificationCenter = .default
    ) {
        self.manager = manager
        self.accountEmail = accountEmail
        self.requestSync = requestSync
        notificationCenter.publisher(for: .syncCompleted)
            .merge(with: notificationCenter.publisher(for: .syncMessagesAbandoned))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    /// The production model, fed by the shared ledger and the foreground sync.
    convenience init(deps: Dependencies) {
        let authSession = deps.authSession
        let foregroundSyncCoordinator = deps.foregroundSyncCoordinator
        self.init(
            manager: deps.syncFailureTracker,
            accountEmail: { [weak authSession] in authSession?.currentOrPersistedUserEmail() },
            requestSync: { [weak foregroundSyncCoordinator] in
                foregroundSyncCoordinator?.triggerSync(reason: "exhaustedMessagesRetry", force: true)
            }
        )
    }

    func refresh() {
        readGeneration &+= 1
        let generation = readGeneration
        let manager = self.manager
        Task { [weak self] in
            let ids = await manager.fetchExhaustedMessageIds()
            self?.publish(ids, readGeneration: generation)
        }
    }

    /// Hides the banner at once, gives the rows back and asks for a sync; the
    /// sync's completion re-reads, so a message that fails again five times
    /// brings the banner back.
    func retryAll() {
        readGeneration &+= 1
        summary = nil
        let manager = self.manager
        Task { [weak self] in
            let gaveBack = await manager.retryExhaustedMessages()
            guard let self else { return }
            if gaveBack {
                self.requestSync()
            }
            self.refresh()
        }
    }

    /// The first message given up on, in Gmail on the web.
    var gmailURL: URL? {
        guard let summary else { return nil }
        return ExhaustedSyncMessagesPolicy.gmailWebURL(
            forMessageId: summary.firstGmailMessageId,
            accountEmail: accountEmail()
        )
    }

    private func publish(_ ids: [String]?, readGeneration generation: UInt64) {
        guard generation == readGeneration else { return }
        // An unreadable ledger keeps what is on screen rather than hiding it.
        guard let ids else { return }
        summary = ExhaustedSyncMessagesPolicy.summary(forExhaustedMessageIds: ids)
    }
}
