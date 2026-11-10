import Foundation

/// Acts on the Settings app's Sign Out switch for `ContentView`, which only
/// decides *when* to look (on appear, on returning to the foreground or
/// regaining focus, and when authentication changes) and draws the overlay.
/// What a look does — which signal judges the request, when it is cleared,
/// and the confirmed sign-out — lives here so tests can drive it with a fake
/// account and prompter (`SettingsAppSignOutControllerTests`).
///
/// The Mac has no Settings app page. Its Sign Out… menu command asks through
/// `requestSignOut(account:focusedWindowHasSheet:)` instead, and reaches the
/// same confirmation and the same single `signOut()`.
@MainActor
final class SettingsAppSignOutController: ObservableObject {
    /// True from a confirmed Settings-app sign-out until `signOut()` returns.
    /// `AuthSession` publishes no "signing out" state, and the mailbox stays on
    /// screen until teardown reaches `isAuthenticated = false`; the cleanup
    /// that follows runs behind the same overlay.
    @Published private(set) var isSigningOut = false

    /// Whether an account is still held on this device while nobody is signed in: a launch
    /// restore that failed retryably shows `SignInView` over credentials, a store and body
    /// files that are all still there. The Mac's Sign Out… command is enabled from it
    /// (`SignOutMenuPolicy.isEnabled`). It is a cached answer, because the live one
    /// (`isDurablySignedOut()`) reads the keychain while signed out and the command's state is
    /// computed in a view body; `refreshHeldAccount` renews it. Stays false on iOS, which has
    /// no command and never refreshes it.
    @Published private(set) var holdsAccountWhileSignedOut = false

    private let preferences: SettingsAppPreferences
    private let prompter: SettingsAppSignOutPrompting

    /// `prompter` defaults inside the body: `PlatformSettingsAppSignOutPrompter`
    /// is main-actor isolated, and a default argument is evaluated in the
    /// caller's (here nonisolated) context.
    init(
        preferences: SettingsAppPreferences = SettingsAppPreferences(),
        prompter: SettingsAppSignOutPrompting? = nil
    ) {
        self.preferences = preferences
        self.prompter = prompter ?? PlatformSettingsAppSignOutPrompter()
    }

    /// The prompter when it is the SwiftUI-alert one (the Mac's default), which
    /// `ContentView` must host; nil for UIKit or injected prompters.
    var alertPrompter: SettingsAppSignOutAlertPrompter? {
        prompter as? SettingsAppSignOutAlertPrompter
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
            presentConfirmation(account: account)
        }
    }

    /// The Mac's Sign Out… menu command (`SignOutCommands`): asks at once, through the
    /// policy the Settings-app switch is judged by, and returns what it did so the command
    /// can beep when it asked nothing.
    ///
    /// It stores no request. The iOS switch is a stored value because the Settings app is
    /// another process, and the user can see it there. The command runs in this process: a
    /// stored request would outlive a force quit made before the alert was answered and ask
    /// "Sign Out of MushMail?" at the next launch with no switch on screen to explain it, and
    /// a second window, which has its own controller, would ask about the first window's
    /// request as soon as it became key.
    ///
    /// A menu command is a foreground action, so this does not wait for the scene to become
    /// active. `focusedWindowHasSheet` is `SignOutMenuPolicy.choice`'s.
    @discardableResult
    func requestSignOut(
        account: SettingsAppSignOutAccount,
        focusedWindowHasSheet: Bool
    ) -> SignOutMenuPolicy.Choice {
        let isDurablySignedOut = account.isDurablySignedOut()
        // The command was enabled from the cached answer; this one is fresh.
        setHoldsAccountWhileSignedOut(!account.isAuthenticated && !isDurablySignedOut)
        let choice = SignOutMenuPolicy.choice(
            focusedWindowHasSheet: focusedWindowHasSheet,
            decision: SettingsAppSignOutPolicy.decision(
                isSignOutRequested: true,
                isDurablySignedOut: isDurablySignedOut,
                isRequestBeingHandled: isSigningOut || prompter.isConfirmationActive,
                isSceneActive: true
            )
        )
        if choice == .confirm {
            presentConfirmation(account: account)
        }
        return choice
    }

    /// Renews `holdsAccountWhileSignedOut`. The Mac calls it where `ContentView` already looks
    /// at the account: when the window appears and when authentication changes
    /// (`SignOutMenuActionPublisher`). iOS never does, so it gains no keychain read. While
    /// signed in the answer is false without asking `isDurablySignedOut()`.
    func refreshHeldAccount(account: SettingsAppSignOutAccount) {
        setHoldsAccountWhileSignedOut(!account.isAuthenticated && !account.isDurablySignedOut())
    }

    /// Publishes only a change: both callers run on events that usually leave it as it was.
    private func setHoldsAccountWhileSignedOut(_ holds: Bool) {
        guard holdsAccountWhileSignedOut != holds else { return }
        holdsAccountWhileSignedOut = holds
    }

    /// Asks the user to confirm signing out `account`. Both answers clear the Settings-app
    /// request; after the Mac's menu command there is none stored, and clearing an absent key
    /// changes nothing.
    private func presentConfirmation(account: SettingsAppSignOutAccount) {
        prompter.presentConfirmation(
            accountEmail: SettingsAppPreferences.displayedAccountEmail(
                isAuthenticated: account.isAuthenticated,
                userEmail: account.userEmail
            ),
            onSignOut: { [weak self] in self?.signOutConfirmed(account: account) },
            onCancel: { [weak self] in self?.preferences.clearSignOutRequest() }
        )
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
