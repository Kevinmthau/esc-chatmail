import Foundation

/// Runs a held account's launch restore again (`LaunchRestoreRetryPolicy`): on Try Again,
/// when the app comes to the foreground, when the network path returns, and after a
/// backoff while the path is usable but Google is not reached.
///
/// One attempt at a time, and only while an account is held (`AuthSession.heldAccount`
/// with no session published): a sign-in, a sign-out or a terminal restore ends the hold,
/// and the next wait that ends finds nothing to do. Started by `initializeApp()` once the
/// app is initialized, so no retry can run ahead of the launch's own restore.
///
/// The restore it runs publishes the session itself, with every boundary rule of the
/// launch's (`AuthSession.restorePreviousSignIn()`), and the app's auth observers then
/// start sync as they do for any sign-in.
@MainActor
final class LaunchRestoreRetryCoordinator: ObservableObject {
    static let shared = LaunchRestoreRetryCoordinator(
        restore: {
            _ = await AppStartupBootstrap.shared.restoreAuthenticationIfNeeded()
        },
        hasHeldAccount: {
            AuthSession.shared.heldAccount != nil && !AuthSession.shared.isAuthenticated
        }
    )

    /// True while an attempt this coordinator started is running. A restore a
    /// background task started is not counted.
    @Published private(set) var isRestoring = false

    private let restore: @MainActor @Sendable () async -> Void
    private let hasHeldAccount: @MainActor () -> Bool
    private let pathMonitor: OutboundNetworkPathMonitoring
    private let sleep: @Sendable (TimeInterval) async -> Bool
    private let now: @Sendable () -> Date

    private var isStarted = false
    private var isPaused = false
    private var consecutiveFailures = 0
    private var lastAttemptStartedAt: Date?
    private var attemptTask: Task<Void, Never>?
    private var scheduledRetry: Task<Void, Never>?
    /// Names the scheduled retry, so a wait that ended after it was replaced
    /// cannot clear its replacement.
    private var scheduledRetryID: UUID?

    init(
        restore: @escaping @MainActor @Sendable () async -> Void,
        hasHeldAccount: @escaping @MainActor () -> Bool,
        pathMonitor: OutboundNetworkPathMonitoring = OutboundNetworkPathMonitor.shared,
        sleep: @escaping @Sendable (TimeInterval) async -> Bool = { seconds in
            await Task.sleepUnlessCancelled(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.restore = restore
        self.hasHeldAccount = hasHeldAccount
        self.pathMonitor = pathMonitor
        self.sleep = sleep
        self.now = now
    }

    /// Called once, at the end of `initializeApp()`. A held account then has the launch's
    /// failed attempt behind it, and the first wait begins. `isInBackground` is UIKit's
    /// live state: an iOS app initialized in the background waits for its first
    /// activation instead.
    func start(isInBackground: Bool) {
        guard !isStarted else { return }
        isStarted = true
        isPaused = isInBackground
        consecutiveFailures = 1
        scheduleAutomaticRetryIfHeld()
    }

    func handle(_ response: LaunchRestoreRetryPolicy.LifecycleResponse) {
        guard isStarted else { return }
        switch response {
        case .none:
            break
        case .pause:
            isPaused = true
            cancelScheduledRetry()
        case .retry:
            isPaused = false
            if attempt(.cameToForeground) {
                return
            }
            // Refused (one is running, or one started a moment ago): the wait that
            // a pause cancelled starts again.
            scheduleAutomaticRetryIfHeld()
        }
    }

    /// Try Again on the held screen.
    func retryNow() {
        guard isStarted else { return }
        _ = attempt(.userAsked)
    }

    /// Whether a retry is waiting for the path or the backoff. For tests.
    var isRetryScheduled: Bool {
        scheduledRetry != nil
    }

    @discardableResult
    private func attempt(_ trigger: LaunchRestoreRetryPolicy.Trigger) -> Bool {
        let shouldAttempt = LaunchRestoreRetryPolicy.shouldAttempt(
            trigger: trigger,
            hasHeldAccount: hasHeldAccount(),
            isAttemptInFlight: attemptTask != nil,
            secondsSinceLastAttemptStarted: lastAttemptStartedAt.map { now().timeIntervalSince($0) }
        )
        guard shouldAttempt else { return false }
        if trigger == .cameToForeground || trigger == .userAsked {
            // A new start: the backoff after this attempt is the first one's again.
            consecutiveFailures = 0
        }
        cancelScheduledRetry()
        lastAttemptStartedAt = now()
        isRestoring = true
        let restore = self.restore
        attemptTask = Task { [weak self] in
            await restore()
            self?.attemptDidFinish()
        }
        return true
    }

    private func attemptDidFinish() {
        attemptTask = nil
        isRestoring = false
        guard hasHeldAccount() else {
            consecutiveFailures = 0
            return
        }
        consecutiveFailures += 1
        scheduleAutomaticRetryIfHeld()
    }

    /// Waits for the path if it is known to be down (and then `pathReturnSettleDelay`),
    /// else for the backoff (and then for the path, if it went down meanwhile), and then
    /// tries.
    private func scheduleAutomaticRetryIfHeld() {
        guard isStarted, !isPaused, attemptTask == nil, scheduledRetry == nil, hasHeldAccount() else {
            return
        }
        let delay = LaunchRestoreRetryPolicy.automaticRetryDelay(
            afterConsecutiveFailures: consecutiveFailures
        )
        let pathMonitor = self.pathMonitor
        let sleep = self.sleep
        // Decided now, not when the task first runs: a path that comes back in
        // between must still end the wait at once, not start the backoff.
        let waitsForPathOnly = pathMonitor.isPathKnownUnsatisfied
        let id = UUID()
        scheduledRetryID = id
        scheduledRetry = Task { [weak self] in
            do {
                if waitsForPathOnly {
                    try await pathMonitor.waitUntilPathSatisfied()
                    guard await sleep(LaunchRestoreRetryPolicy.pathReturnSettleDelay) else { return }
                } else {
                    guard await sleep(delay) else { return }
                }
                try await pathMonitor.waitUntilPathSatisfied()
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.scheduledRetryDidFire(id: id)
        }
    }

    private func scheduledRetryDidFire(id: UUID) {
        guard scheduledRetryID == id else { return }
        scheduledRetry = nil
        scheduledRetryID = nil
        attempt(.scheduled)
    }

    private func cancelScheduledRetry() {
        scheduledRetry?.cancel()
        scheduledRetry = nil
        scheduledRetryID = nil
    }
}
