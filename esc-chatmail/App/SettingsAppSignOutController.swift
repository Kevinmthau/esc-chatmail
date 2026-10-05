import Foundation

/// Acts on the Settings app's Sign Out switch for `ContentView`, which only
/// decides *when* to look (on appear, on returning to the foreground or
/// regaining focus, and when authentication changes) and draws the overlay.
/// What a look does — which signal judges the request, when it is cleared,
/// and the confirmed sign-out — lives here so tests can drive it with a fake
/// account and prompter (`SettingsAppSignOutControllerTests`).
@MainActor
final class SettingsAppSignOutController: ObservableObject {
    /// True from a confirmed Settings-app sign-out until `signOut()` returns.
    /// `AuthSession` publishes no "signing out" state, and the mailbox stays on
    /// screen until teardown reaches `isAuthenticated = false`; the cleanup
    /// that follows runs behind the same overlay.
    @Published private(set) var isSigningOut = false

    private let preferences: SettingsAppPreferences
    private let prompter: SettingsAppSignOutPrompting

    /// `prompter` defaults inside the body: `SettingsAppSignOutPrompter` is
    /// main-actor isolated, and a default argument is evaluated in the
    /// caller's (here nonisolated) context.
    init(
        preferences: SettingsAppPreferences = SettingsAppPreferences(),
        prompter: SettingsAppSignOutPrompting? = nil
    ) {
        self.preferences = preferences
        self.prompter = prompter ?? SettingsAppSignOutPrompter()
    }

    /// Acts on the Settings app's Sign Out switch (`SettingsAppSignOutPolicy`).
    func evaluate(account: SettingsAppSignOutAccount, isSceneActive: Bool) {
        let isSignOutRequested = preferences.isSignOutRequested
        let decision = SettingsAppSignOutPolicy.decision(
            isSignOutRequested: isSignOutRequested,
            // Only asked when there is a request to judge: while signed out,
            // `isDurablySignedOut()` reads the keychain, and this runs on every
            // foregrounding and focus change. It, not `isAuthenticated`, is the
            // signal: see `SettingsAppSignOutPolicy.decision`.
            isDurablySignedOut: isSignOutRequested && account.isDurablySignedOut(),
            isRequestBeingHandled: isSigningOut || prompter.isConfirmationActive,
            isSceneActive: isSceneActive
        )
        switch decision {
        case .none:
            break
        case .discardRequest:
            preferences.clearSignOutRequest()
        case .confirm:
            prompter.presentConfirmation(
                accountEmail: SettingsAppPreferences.displayedAccountEmail(
                    isAuthenticated: account.isAuthenticated,
                    userEmail: account.userEmail
                ),
                onSignOut: { [weak self] in self?.signOutConfirmed(account: account) },
                onCancel: { [weak self] in self?.preferences.clearSignOutRequest() }
            )
        }
    }

    /// The sign-out the Settings-app confirmation approved: the same
    /// `AuthSession.signOut()` the old in-app Settings screen called. It starts
    /// from UI, never from inside another auth transition (the auth gate is
    /// not reentrant).
    private func signOutConfirmed(account: SettingsAppSignOutAccount) {
        preferences.clearSignOutRequest()
        // The alert can outlive the session it was raised for (a sign-out from
        // elsewhere, or a restore whose credentials were rejected, finished
        // while it was up); once durably signed out there is no session left
        // for this switch to end — the same verdict the policy discards on.
        guard !account.isDurablySignedOut(), !isSigningOut else { return }
        isSigningOut = true
        Task {
            let didSignOut = await account.signOut()
            isSigningOut = false
            if !didSignOut {
                // Cleanup never began (the reset marker could not be saved), so
                // the account is still signed in; say so rather than nothing.
                Log.error("Settings-app sign-out did not start; the account is still signed in", category: .auth)
                prompter.presentFailure()
            }
        }
    }
}
