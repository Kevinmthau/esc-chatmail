import SwiftUI

extension View {
    /// Shows the Settings-app sign-out alerts `controller` raises, where they are SwiftUI alerts:
    /// on the Mac (`SettingsAppSignOutAlertPrompter`). Changes nothing on iOS, whose prompter
    /// presents UIKit alerts itself, or for a controller given another prompter.
    @ViewBuilder
    func settingsAppSignOutAlerts(for controller: SettingsAppSignOutController) -> some View {
        #if os(iOS)
        self
        #else
        if let prompter = controller.alertPrompter {
            modifier(SettingsAppSignOutAlertModifier(prompter: prompter))
        } else {
            self
        }
        #endif
    }
}
