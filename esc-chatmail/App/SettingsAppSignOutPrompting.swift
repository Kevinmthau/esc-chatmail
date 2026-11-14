import Foundation

/// The confirmation and failure UI of a Settings-app sign-out.
/// `SettingsAppSignOutPrompter` is the UIKit implementation (iOS) and
/// `SettingsAppSignOutAlertPrompter` the SwiftUI-alert one (the Mac); tests
/// substitute a fake that captures the action handlers.
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
    /// Takes a confirmation that is on screen off it, unanswered: neither handler runs, as
    /// when the prompt is torn down any other way, and `isConfirmationActive` is false when
    /// this returns. `SettingsAppSignOutController` calls it when the session the
    /// confirmation asked about is no longer the one there.
    ///
    /// A confirmation that is not on screen to be taken down yet (still waiting to be
    /// presented, or still coming up) is left, and `isConfirmationActive` stays true: the
    /// caller asks again the next time it looks. Does nothing when there is no confirmation.
    func withdrawConfirmation()
    /// Tells the user a confirmed sign-out never started.
    func presentFailure()
}
