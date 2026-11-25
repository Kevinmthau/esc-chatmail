#if os(iOS)
import Foundation

/// How one background-task run ended, as `BackgroundRunJournal` records it, and what that
/// tells iOS (`reportsSuccess`, before an expiration forces failure).
enum BackgroundRunOutcome: String, Codable, CaseIterable, Sendable {
    /// The mailbox run completed.
    case completed
    /// The run stopped short; a catch-up retry was scheduled.
    case needsFollowUp
    /// Another run held the boundary; a retry was scheduled.
    case blockedRetrying
    /// Another run held the boundary, and nothing needed retrying.
    case blockedNoRetry
    /// The run failed; the failure backoff was scheduled.
    case failed
    /// Skipped: the device is too full to sync.
    case deferredForInsufficientStorage
    /// The account was signed out for good: a successful no-op (and the cadence was swept).
    case signedOut
    /// No usable session, though the account is not signed out: the launch restore
    /// failed with the account held (offline, Google unreachable), or the session needs a
    /// new sign-in (a revoked token). Reported as success, as it always was, so the cadence
    /// lives on; worth a warning, since every run like it is a mailbox that did not sync.
    case noSessionYet
    /// Written when the task fires and replaced when it completes. One that is still there
    /// is a run the process did not live to complete (killed by the watchdog or jetsam).
    case started
    /// The launch's persistence or auth restore did not get ready.
    case notReady
    /// The run was cancelled, by expiration or before it began.
    case cancelled
    /// A maintenance task's handler returned success.
    case maintenanceSucceeded
    /// A maintenance task's handler returned failure.
    case maintenanceFailed

    var reportsSuccess: Bool {
        switch self {
        case .completed, .blockedNoRetry, .signedOut, .noSessionYet, .maintenanceSucceeded:
            return true
        case .needsFollowUp, .blockedRetrying, .failed, .deferredForInsufficientStorage,
             .notReady, .cancelled, .maintenanceFailed, .started:
            return false
        }
    }

    /// An ending worth one warning line in a Release build.
    var isAbnormal: Bool {
        switch self {
        case .failed, .notReady, .noSessionYet, .maintenanceFailed:
            return true
        default:
            return false
        }
    }
}
#endif
