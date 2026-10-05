import UIKit

/// Presents the confirmation for a Settings-app sign-out request, as a UIKit
/// alert from the topmost presentable view controller.
///
/// Not a SwiftUI `.alert`/`.confirmationDialog` on `ContentView`: those present
/// from the root hosting controller, which is already presenting whenever a
/// Compose or chat sheet is up, so the prompt would silently never appear.
/// `TopPresentableViewController` shows it over whatever is on screen.
///
/// The alert is held weakly: one torn down with the sheet it was shown over
/// calls neither action handler, so a strong reference or a plain "prompt
/// showing" flag would then report the request as handled until relaunch and
/// block every later prompt.
///
/// Not actor-isolated so `ContentView` can create it as an `@State` default;
/// every member that touches state is `@MainActor`.
final class SettingsAppSignOutPrompter {
    private weak var presentedAlert: UIAlertController?
    private var isAwaitingPresenter = false

    /// Whether a confirmation is on screen or about to be.
    @MainActor
    var isConfirmationActive: Bool {
        isAwaitingPresenter || presentedAlert?.presentingViewController != nil
    }

    /// Presents the confirmation. When no view controller can present within
    /// `TopPresentableViewController.present`'s retry window it logs and gives
    /// up, leaving the request pending for the next foregrounding.
    @MainActor
    func presentConfirmation(
        accountEmail: String?,
        onSignOut: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard !isConfirmationActive else { return }

        let alert = UIAlertController(
            title: "Sign Out of MushMail?",
            message: "\(accountEmail ?? "This account") will be signed out and its mail removed from this device.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in onCancel() })
        alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { _ in onSignOut() })

        isAwaitingPresenter = true
        Task { @MainActor [weak self] in
            let didPresent = await TopPresentableViewController.present(alert)
            guard let self else { return }
            self.isAwaitingPresenter = false
            if didPresent {
                self.presentedAlert = alert
            } else {
                Log.warning(
                    "No view controller could present the Settings-app sign-out confirmation; the request stays pending",
                    category: .ui
                )
            }
        }
    }

    /// Tells the user a confirmed sign-out never started (its reset marker
    /// could not be saved), so the app is still signed in.
    @MainActor
    func presentFailure() {
        let alert = UIAlertController(
            title: "Couldn’t Sign Out",
            message: "MushMail is still signed in. Turn on Sign Out in Settings to try again.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        Task { @MainActor in
            await TopPresentableViewController.present(alert)
        }
    }
}
