import SwiftUI

/// Shows `SettingsAppSignOutAlertPrompter`'s alerts. Applied to `ContentView` on the Mac only
/// (`View.settingsAppSignOutAlerts(for:)`); iOS presents the same prompts through UIKit.
///
/// The confirmation and the failure are two presentations, each with a binding of its own.
/// They were one, and SwiftUI reports that an alert has left the screen through the binding
/// of the newest `body`, whichever alert that `body` was drawn for. A failure raised while
/// the confirmation was still leaving (a stale answer raises it inside the confirmation's own
/// answer, `SettingsAppSignOutController.signOutConfirmed`) was then the alert the
/// confirmation's dismissal was reported for: it was cleared before it was shown, and the
/// answer said nothing. With a presentation each, the confirmation's dismissal is reported to
/// a binding that holds no alert, and the failure comes up once the confirmation has gone.
/// Both were measured in a stand-in program built from this file (macOS 27.2, 2026-11-13).
///
/// What one presentation still does not do is change the alert it has on screen: with one
/// confirmation taken down and another raised in the same turn, the first stayed up. Nothing
/// does that on the Mac (`SettingsAppSignOutController.withdrawStaleConfirmation`).
struct SettingsAppSignOutAlertModifier: ViewModifier {
    @ObservedObject var prompter: SettingsAppSignOutAlertPrompter

    func body(content: Content) -> some View {
        let presented = prompter.alert
        let confirmation = presented.flatMap { $0.isConfirmation ? $0 : nil }
        let failure = presented.flatMap { $0.isConfirmation ? nil : $0 }
        return alert(failure, on: alert(confirmation, on: content))
    }

    /// One presentation. `presented` is the prompter's alert when it is of this presentation's
    /// kind, and nil otherwise.
    private func alert(
        _ presented: SettingsAppSignOutAlertPrompter.Alert?,
        on content: some View
    ) -> some View {
        content.alert(
            presented?.title ?? "",
            isPresented: Binding(
                get: { presented != nil },
                set: { isPresented in
                    if !isPresented, let presented {
                        prompter.alertDidDismiss(presented)
                    }
                }
            ),
            presenting: presented
        ) { alert in
            switch alert.kind {
            case .confirmation:
                Button("Cancel", role: .cancel) {
                    prompter.answer(alert, signOut: false)
                }
                Button("Sign Out", role: .destructive) {
                    prompter.answer(alert, signOut: true)
                }
            case .failure:
                Button("OK", role: .cancel) {
                    prompter.answer(alert, signOut: false)
                }
            }
        } message: { alert in
            Text(alert.message)
        }
    }
}
