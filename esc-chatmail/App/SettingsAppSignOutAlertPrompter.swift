import Foundation

/// The Settings-app sign-out confirmation and failure as SwiftUI alerts: the Mac's
/// `SettingsAppSignOutPrompting` (`PlatformSettingsAppSignOutPrompter`), shown by
/// `SettingsAppSignOutAlertModifier` on `ContentView`.
///
/// iOS keeps `SettingsAppSignOutPrompter`, a UIKit alert from the topmost view controller: a
/// SwiftUI alert on the root view never appears there while a Compose or chat sheet is up. On the
/// Mac a window shows one sheet at a time, so an alert raised under a sheet waits for it to close,
/// and the request stays held (`isConfirmationActive`) until the user answers it.
///
/// The Mac has no Settings app page (`Settings.bundle` is iOS-only), so until the Mac gets its own
/// Settings scene, the app menu's Sign Out… command (`SignOutCommands`) is what raises a sign-out
/// request there.
///
/// The alert is published as a value. `answer(_:signOut:)` runs exactly one of its handlers; when
/// the alert leaves the screen any other way, `alertDidDismiss(_:)` clears it and runs neither,
/// as `SettingsAppSignOutPrompting` requires. Both match on the alert's identity, so a late call
/// for an old alert never clears a newer one.
@MainActor
final class SettingsAppSignOutAlertPrompter: ObservableObject, SettingsAppSignOutPrompting {
    /// An alert on screen, or about to be.
    struct Alert: Identifiable {
        enum Kind: Equatable {
            /// Asks to confirm signing out `accountEmail` (nil: no address is known).
            case confirmation(accountEmail: String?)
            /// Says a confirmed sign-out never started.
            case failure
        }

        let id = UUID()
        let kind: Kind
        fileprivate let onSignOut: () -> Void
        fileprivate let onCancel: () -> Void

        var title: String {
            switch kind {
            case .confirmation: return "Sign Out of MushMail?"
            case .failure: return "Couldn’t Sign Out"
            }
        }

        var message: String {
            switch kind {
            case .confirmation(let accountEmail):
                return "\(accountEmail ?? "This account") will be signed out and its mail removed from this device."
            case .failure:
                return "MushMail is still signed in. Turn on Sign Out in Settings to try again."
            }
        }
    }

    @Published private(set) var alert: Alert?

    var isConfirmationActive: Bool {
        guard case .confirmation = alert?.kind else { return false }
        return true
    }

    func presentConfirmation(
        accountEmail: String?,
        onSignOut: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard !isConfirmationActive else { return }
        alert = Alert(kind: .confirmation(accountEmail: accountEmail), onSignOut: onSignOut, onCancel: onCancel)
    }

    func presentFailure() {
        alert = Alert(kind: .failure, onSignOut: {}, onCancel: {})
    }

    /// The user answered `answered` (`signOut` false: Cancel, or OK on the failure alert). Runs
    /// that answer's handler even when SwiftUI already cleared the alert through its binding, which
    /// it may do before the button's action runs.
    func answer(_ answered: Alert, signOut: Bool) {
        if alert?.id == answered.id {
            alert = nil
        }
        if signOut {
            answered.onSignOut()
        } else {
            answered.onCancel()
        }
    }

    /// `dismissed` left the screen; clears it without running either handler.
    func alertDidDismiss(_ dismissed: Alert) {
        guard alert?.id == dismissed.id else { return }
        alert = nil
    }
}
