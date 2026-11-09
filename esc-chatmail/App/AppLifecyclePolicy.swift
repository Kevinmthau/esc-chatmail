import Foundation
import SwiftUI

/// When the app-scoped foreground sync session (`ForegroundSyncCoordinator`)
/// starts and stops, and whether quitting waits for sends, on each platform.
///
/// - **iOS:** the scene going to the background stops the session and arms the
///   BGTask requests; the scene becoming active starts it again.
/// - **Mac:** the app keeps running while its windows are hidden, minimized or
///   closed, and there are no BGTasks. The session therefore runs from the end
///   of `initializeApp()` until quit, and a window's scene phase never stops
///   it. It pauses while the system sleeps (`NSWorkspace.willSleepNotification`)
///   and starts again, syncing at once, on wake and whenever the app becomes
///   active (`MacSystemLifecycleObserver`). Quitting waits up to
///   `outstandingSendTerminationTimeout` for sends in flight.
///
/// The `App` struct runs under no test plan, so these decisions live here
/// (`AppLifecyclePolicyTests`) and the struct only carries them out.
enum AppLifecyclePolicy {
    enum SyncAction: Equatable, Sendable {
        case none
        case startForegroundSync
        case stopForegroundSync
        /// iOS scene background: stop the session, then arm the BGTask
        /// requests (`BackgroundSyncManager.armBackgroundTasksForSceneBackground`).
        case stopForegroundSyncAndArmBackgroundTasks
        /// iOS only: initialization finished after the app went to the
        /// background, so the session must not start, and nothing was armed.
        case armBackgroundTasks
    }

    /// The Mac events the session follows, delivered by
    /// `MacSystemLifecycleObserver`.
    enum SystemEvent: Equatable, Sendable {
        case applicationDidBecomeActive
        case systemWillSleep
        case systemDidWake
    }

    enum TerminationDecision: Equatable, Sendable {
        case terminateNow
        /// Answer `.terminateLater`, then reply once the outstanding sends
        /// finish or `timeout` passes, whichever is first.
        case terminateAfterOutstandingSends(timeout: TimeInterval)
    }

    /// How long quitting waits for sends in flight before it lets the app
    /// quit anyway. A send cut off then is safe: cold recovery converts its
    /// markers at the next launch and never resends.
    static let outstandingSendTerminationTimeout: TimeInterval = 10

    static func syncAction(
        forScenePhase phase: ScenePhase,
        platform: AppPlatform,
        isInitialized: Bool,
        canAccessMailbox: Bool
    ) -> SyncAction {
        switch phase {
        case .background:
            switch platform {
            case .iOS:
                // Unconditional: the BGTask arm applies its own
                // canAccessMailbox gate.
                return .stopForegroundSyncAndArmBackgroundTasks
            case .macOS:
                // A hidden, minimized or closed window. The app keeps running,
                // and so does the session.
                return .none
            }
        case .active:
            // Before initialization finishes, its own completion starts the
            // session once the startup order is satisfied.
            return isInitialized && canAccessMailbox ? .startForegroundSync : .none
        case .inactive:
            return .none
        @unknown default:
            return .none
        }
    }

    /// What `initializeApp()` does once auth is restored.
    /// `isApplicationInBackground` is UIKit's live application state, which
    /// the Mac does not have: there the app counts as in the foreground.
    static func syncActionAfterInitialization(
        platform: AppPlatform,
        isApplicationInBackground: Bool,
        canAccessMailbox: Bool
    ) -> SyncAction {
        // Revoked credentials start no sync work in either direction.
        guard canAccessMailbox else { return .none }
        if platform == .iOS, isApplicationInBackground {
            return .armBackgroundTasks
        }
        return .startForegroundSync
    }

    static func syncAction(
        forSystemEvent event: SystemEvent,
        canAccessMailbox: Bool
    ) -> SyncAction {
        switch event {
        case .systemWillSleep:
            return .stopForegroundSync
        case .systemDidWake, .applicationDidBecomeActive:
            return canAccessMailbox ? .startForegroundSync : .none
        }
    }

    /// Whether an auth change (sign-in, finished reauthentication) may start
    /// the session. On iOS only while the scene is active, since the
    /// background has BGTasks instead. On the Mac whatever the scene phase,
    /// because the session runs while windows are hidden too.
    static func allowsForegroundSyncStartOnAuthChange(
        platform: AppPlatform,
        scenePhase: ScenePhase
    ) -> Bool {
        switch platform {
        case .iOS:
            return scenePhase == .active
        case .macOS:
            return true
        }
    }

    static func terminationDecision(hasOutstandingSends: Bool) -> TerminationDecision {
        hasOutstandingSends
            ? .terminateAfterOutstandingSends(timeout: outstandingSendTerminationTimeout)
            : .terminateNow
    }
}
