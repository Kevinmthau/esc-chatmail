import SwiftUI

/// Shows `SettingsAppSignOutAlertPrompter`'s alerts. Applied to `ContentView` on the Mac only
/// (`View.settingsAppSignOutAlerts(for:)`); iOS presents the same prompts through UIKit.
struct SettingsAppSignOutAlertModifier: ViewModifier {
    @ObservedObject var prompter: SettingsAppSignOutAlertPrompter

    func body(content: Content) -> some View {
        let presented = prompter.alert
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
