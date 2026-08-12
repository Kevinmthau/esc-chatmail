import Foundation

/// Decides what a launch restore must do with the credentials it already staged
/// when account-scoped work could not be reopened.
///
/// `restorePreviousSignIn` persists background-readable tokens *before* the
/// reopen sequence runs, so every refusal leaves live credentials behind and the
/// right disposition depends entirely on why the reopen refused. This is a pure
/// namespace so the decision is testable without a `GIDGoogleUser`.
enum AuthRestoreReopenPolicy {
    enum RestoreDisposition: Equatable, Sendable {
        /// Every subsystem reopened; publish the restored session.
        case publishSession
        /// Keep the staged credentials and report a retryable failure. The next
        /// restore attempt can succeed with exactly these credentials.
        case retryKeepingCredentials
        /// Clear the staged credentials before returning. Retrying cannot help
        /// and nothing else owns them.
        case discardCredentials
    }

    static func restoreDispositionAfterReopen(
        _ outcome: AccountWorkReopenOutcome
    ) -> RestoreDisposition {
        switch outcome {
        case .reopened:
            return .publishSession
        case .transientFailure:
            // File I/O failed while recreating account directories. Nothing is
            // latched: AppStartupBootstrap leaves the restore incomplete and a
            // later `prepareForBackgroundSync` retries it, which needs these
            // credentials to still be there. Clearing them would turn a
            // recoverable hiccup into a forced re-authentication.
            return .retryKeepingCredentials
        case .latchedRefusal:
            // A drain that already awaited every task it owned still left work
            // outstanding, so this transition cannot publish and repeating it is
            // not expected to clear the latch. No superseding transition is
            // running either, which makes this restore the only owner of the
            // credentials it just staged: clear them rather than leave
            // background-readable tokens for a session that never published.
            return .discardCredentials
        case .supersededByAccountRemoval:
            // A queued sign-out won the transition and performs its own
            // credential cleanup. Double-handling would race that teardown, and
            // may destroy credentials the superseding path already replaced.
            return .retryKeepingCredentials
        }
    }
}
