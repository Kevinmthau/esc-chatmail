#if os(iOS)
/// The Settings-app sign-out prompts `SettingsAppSignOutController` uses by default: UIKit alerts
/// from the topmost view controller on iOS, so they appear over any sheet.
typealias PlatformSettingsAppSignOutPrompter = SettingsAppSignOutPrompter
#else
/// The Settings-app sign-out prompts `SettingsAppSignOutController` uses by default: SwiftUI
/// alerts on the Mac, which has no UIKit (`View.settingsAppSignOutAlerts(for:)` shows them).
typealias PlatformSettingsAppSignOutPrompter = SettingsAppSignOutAlertPrompter
#endif
