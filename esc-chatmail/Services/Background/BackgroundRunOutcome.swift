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
    /// Nobody is signed in (or the account was signed out): a successful no-op.
    case noSession
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
        case .completed, .blockedNoRetry, .noSession, .maintenanceSucceeded:
            return true
        case .needsFollowUp, .blockedRetrying, .failed, .deferredForInsufficientStorage,
             .notReady, .cancelled, .maintenanceFailed:
            return false
        }
    }

    /// An ending worth one warning line in a Release build.
    var isAbnormal: Bool {
        switch self {
        case .failed, .notReady, .maintenanceFailed:
            return true
        default:
            return false
        }
    }
}
#endif
