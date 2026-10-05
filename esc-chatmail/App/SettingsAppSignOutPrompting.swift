import Foundation

/// The confirmation and failure UI of a Settings-app sign-out.
/// `SettingsAppSignOutPrompter` is the UIKit implementation; tests substitute
/// a fake that captures the action handlers.
@MainActor
protocol SettingsAppSignOutPrompting: AnyObject {
    /// Whether a confirmation is on screen or about to be.
    var isConfirmationActive: Bool { get }
    /// Asks the user to confirm. Exactly one of `onSignOut` / `onCancel` runs
    /// if the user answers; neither runs if the prompt never appears or is
    /// torn down unanswered.
    func presentConfirmation(
        accountEmail: String?,
        onSignOut: @escaping () -> Void,
        onCancel: @escaping () -> Void
    )
    /// Tells the user a confirmed sign-out never started.
    func presentFailure()
}
