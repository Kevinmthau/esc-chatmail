import Combine
import Foundation

/// Keeps the Settings app's Account and Version rows (`SettingsAppPreferences`)
/// current for the whole process, whether or not any UI is mounted.
///
/// Started from `esc_chatmailApp.init`, which runs on every launch — including
/// a cold background (BGTask) launch whose restore can end the session with no
/// scene connected (`AuthSession.clearFailedGoogleSession`). A writer in
/// `ContentView` misses those: it mounts only after a foreground launch's
/// restore, so Settings kept naming an account the app had already dropped
/// until the app was next opened.
@MainActor
final class SettingsAppAccountPublisher {
    static let shared = SettingsAppAccountPublisher()

    private var accountSubscription: AnyCancellable?

    /// Publishes the app version once, and the account now and on every change
    /// to the session's `isAuthenticated` or `userEmail`. Calling it again
    /// replaces the earlier subscription.
    func start(
        observing authSession: AuthSession,
        preferences: SettingsAppPreferences = SettingsAppPreferences(),
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) {
        preferences.publishAppVersion(SettingsAppPreferences.versionDisplayString(infoDictionary: infoDictionary))
        // `@Published` emits from `willSet`, so each pair carries the value
        // being assigned rather than the one it replaces. Teardown clears
        // `userEmail` before `isAuthenticated`; either change alone already
        // maps to nil, so the row never names a dropped account in between.
        accountSubscription = authSession.$isAuthenticated
            .combineLatest(authSession.$userEmail)
            .sink { isAuthenticated, userEmail in
                preferences.publishAccountEmail(
                    SettingsAppPreferences.displayedAccountEmail(
                        isAuthenticated: isAuthenticated,
                        userEmail: userEmail
                    )
                )
            }
    }
}
