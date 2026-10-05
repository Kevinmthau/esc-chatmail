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
///
/// Fresh-install cleanup wipes the whole defaults domain after `start` ran, so
/// `AppStartupBootstrap` calls `publishAppVersion()` again once it finishes.
@MainActor
final class SettingsAppAccountPublisher {
    static let shared = SettingsAppAccountPublisher()

    private let preferences: SettingsAppPreferences
    private let infoDictionary: [String: Any]?
    private var accountSubscription: AnyCancellable?

    init(
        preferences: SettingsAppPreferences = SettingsAppPreferences(),
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) {
        self.preferences = preferences
        self.infoDictionary = infoDictionary
    }

    /// Publishes the app version, the session's account if it has one, and the
    /// account again on every later change to the session's `isAuthenticated`
    /// or `userEmail`. Calling it again replaces the earlier subscription.
    ///
    /// The session's state at `start` never clears the row. At App.init it is
    /// always the unrestored `(false, nil)` placeholder, not a sign-out
    /// verdict: a launch that restores nothing (a maintenance BGTask) or fails
    /// retryably (offline) still has the account on the device, and the row
    /// must keep naming it. Every real teardown or reject path reassigns
    /// `userEmail` / `isAuthenticated`, and `@Published` emits on each
    /// assignment even when the value is unchanged, so those still clear it.
    func start(observing authSession: AuthSession) {
        publishAppVersion()
        if let email = SettingsAppPreferences.displayedAccountEmail(
            isAuthenticated: authSession.isAuthenticated,
            userEmail: authSession.userEmail
        ) {
            preferences.publishAccountEmail(email)
        }
        // `@Published` replays the current value on subscribe (dropped here,
        // handled above) and then emits from `willSet`, so each later pair
        // carries the value being assigned rather than the one it replaces.
        // Teardown clears `userEmail` before `isAuthenticated`; either change
        // alone already maps to nil, so the row never names a dropped account
        // in between.
        let preferences = preferences
        accountSubscription = authSession.$isAuthenticated
            .combineLatest(authSession.$userEmail)
            .dropFirst()
            .sink { isAuthenticated, userEmail in
                preferences.publishAccountEmail(
                    SettingsAppPreferences.displayedAccountEmail(
                        isAuthenticated: isAuthenticated,
                        userEmail: userEmail
                    )
                )
            }
    }

    /// Writes the Version row (on change only). `start` calls it; call it again
    /// after anything wipes the defaults domain.
    func publishAppVersion() {
        preferences.publishAppVersion(SettingsAppPreferences.versionDisplayString(infoDictionary: infoDictionary))
    }
}
