import Foundation
import SwiftUI

/// When a held account's launch restore is run again (`LaunchRestoreRetryCoordinator`).
///
/// A launch restore that cannot reach Google keeps the account and holds it
/// (`AuthSession.heldAccount`). Before this, nothing in the foreground ran the restore
/// again: the account came back only at the next launch online, or on iOS when a
/// background task left pending by an earlier session happened to run. The Mac had no
/// way back at all (architecture review 2026-11, `startup-lifecycle#1`).
///
/// A retry is always `AppStartupBootstrap.restoreAuthenticationIfNeeded()`, the launch's
/// own single-flight restore, started from outside any auth transition: it joins a
/// restore already running (a background task's) and waits behind the gate for any
/// other transition. Never `AuthSession.restorePreviousSignIn()` directly, and never from
/// a token refresh or anything else that holds a run or a lease: a restore quiesces sync,
/// and a lease holder waiting on it deadlocks.
enum LaunchRestoreRetryPolicy {
    enum Trigger: Equatable, Sendable {
        /// iOS: the scene became active. Mac: the app became active, or the system woke.
        case cameToForeground
        /// Try Again on the held screen.
        case userAsked
        /// The wait after a failed attempt ended: the network path returned, or the
        /// backoff ran out.
        case scheduled
    }

    /// What a lifecycle event does to the retries.
    enum LifecycleResponse: Equatable, Sendable {
        case none
        /// Try now, and wait for the next chance again if that is refused.
        case retry
        /// Stop waiting: the iOS app is going to the background or the Mac is going to
        /// sleep. The next `.retry` waits again.
        case pause
    }

    /// The least time between the start of one attempt and a foreground event's. The
    /// Mac reports a wake and an activation together, and an offline attempt fails at
    /// once, so without it every switch back to the app started a restore, with its
    /// quiescence, for an answer known a moment earlier.
    static let minimumForegroundInterval: TimeInterval = 5
    /// The wait after the first failed attempt while the path is usable, doubled after
    /// each failure up to `maximumAutomaticRetryDelay`. Covers a path that is "satisfied"
    /// but reaches nothing (a captive portal, a link that stalls), where no path change
    /// will come.
    static let initialAutomaticRetryDelay: TimeInterval = 15
    static let maximumAutomaticRetryDelay: TimeInterval = 300

    static func shouldAttempt(
        trigger: Trigger,
        hasHeldAccount: Bool,
        isAttemptInFlight: Bool,
        secondsSinceLastAttemptStarted: TimeInterval?
    ) -> Bool {
        guard hasHeldAccount, !isAttemptInFlight else { return false }
        switch trigger {
        case .userAsked, .scheduled:
            return true
        case .cameToForeground:
            guard let secondsSinceLastAttemptStarted else { return true }
            return secondsSinceLastAttemptStarted >= minimumForegroundInterval
        }
    }

    /// How long to wait, with the path usable, after `consecutiveFailures` attempts
    /// have failed in a row (the launch's own counts as the first).
    static func automaticRetryDelay(afterConsecutiveFailures consecutiveFailures: Int) -> TimeInterval {
        let doublings = max(0, min(consecutiveFailures - 1, 16))
        let delay = initialAutomaticRetryDelay * pow(2, Double(doublings))
        return min(delay, maximumAutomaticRetryDelay)
    }

    /// iOS acts on the scene; the Mac follows `MacSystemLifecycleObserver`'s events
    /// instead (`response(toSystemEvent:)`), because its scene phase follows the window,
    /// which can be hidden while the app is in front.
    static func response(toScenePhase phase: ScenePhase, platform: AppPlatform) -> LifecycleResponse {
        guard platform == .iOS else { return .none }
        switch phase {
        case .active:
            return .retry
        case .background:
            return .pause
        case .inactive:
            return .none
        @unknown default:
            return .none
        }
    }

    static func response(toSystemEvent event: AppLifecyclePolicy.SystemEvent) -> LifecycleResponse {
        switch event {
        case .applicationDidBecomeActive, .systemDidWake:
            return .retry
        case .systemWillSleep:
            return .pause
        }
    }
}
