import Combine
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
/// same confirmation and the same single `signOut()`. So does the Sign Out… button
/// in its Settings window, which has a controller of its own; what the two
/// windows' controllers share is `SettingsAppSignOutActivity`.
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
    private let activity: SettingsAppSignOutActivity
    private var activityObservation: AnyCancellable?

    /// Whether the window that shows this controller's alerts is on screen. Always true
    /// unless a window says otherwise (`setAlertHost(isOnScreen:)`).
    private var alertHostIsOnScreen: @MainActor () -> Bool = { true }

    /// Asked when a confirmation is answered with Sign Out, before the sign-out starts. True
    /// refuses it, and has told the user so. Never refuses unless a window gives its own
    /// (`init`).
    private let refusesConfirmedSignOut: @MainActor () -> Bool

    /// `prompter` and `activity` default inside the body: `PlatformSettingsAppSignOutPrompter`
    /// and `SettingsAppSignOutActivity.shared` are main-actor isolated, and a default
    /// argument is evaluated in the caller's (here nonisolated) context.
    ///
    /// - Parameter showsFailuresOfOffScreenWindows: True for the controller of a window that
    ///   is on screen for as long as the app runs: the mailbox's (`ContentView`). It then
    ///   shows the failure of a sign-out another window started and can no longer report
    ///   (`SettingsAppSignOutActivity.showFailureInFallbackWindow()`).
    /// - Parameter refusesConfirmedSignOut: A last look when the user answers Sign Out, for a
    ///   window whose confirmation does not block what the sign-out would take away. The
    ///   Mac's Settings window gives one (`MailboxWindowSheet.refusesSignOutConfirmedElsewhere`):
    ///   its alert is a sheet on the Settings window only, so New Message can be opened on
    ///   the mailbox window after the question was asked and before it is answered. True
    ///   refuses the sign-out, and the closure is what tells the user. The mailbox window
    ///   gives none: its own alert is the sheet on it.
    init(
        preferences: SettingsAppPreferences = SettingsAppPreferences(),
        prompter: SettingsAppSignOutPrompting? = nil,
        activity: SettingsAppSignOutActivity? = nil,
        showsFailuresOfOffScreenWindows: Bool = false,
        refusesConfirmedSignOut: (@MainActor () -> Bool)? = nil
    ) {
        let activity = activity ?? .shared
        let prompter = prompter ?? PlatformSettingsAppSignOutPrompter()
        self.preferences = preferences
        self.prompter = prompter
        self.activity = activity
        self.refusesConfirmedSignOut = refusesConfirmedSignOut ?? { false }
        // Named weakly: the activity outlives every window, and must not keep a closed
        // window's controller, or go on asking it.
        activity.addConfirmationSource { [weak self] in
            self?.prompter.isConfirmationActive
        }
        // A sign-out another window's controller runs changes `isAnySignOutRunning` here, so
        // it must redraw what observes this controller: the Sign Out… command and button.
        activityObservation = activity.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        if showsFailuresOfOffScreenWindows {
            activity.setFailureFallback { [weak self] in
                guard let self else { return false }
                self.prompter.presentFailure()
                return true
            }
        }
    }

    /// True while any window's confirmed sign-out is running, this one's included. The Mac's
    /// Sign Out… command and button are disabled from it (`SignOutMenuAction`), so they read
    /// as busy in every window. `isSigningOut` stays this controller's own: it draws the
    /// progress in the window that started the sign-out.
    var isAnySignOutRunning: Bool {
        isSigningOut || activity.isSigningOut
    }

    /// Tells the controller how to ask whether the window that shows its alerts is on screen
    /// (`MacWindowVisibilityProbe`). The Mac's Settings window can be closed while its
    /// sign-out runs, and a failure alert raised then would wait, unseen, for the window to
    /// be opened again.
    func setAlertHost(isOnScreen: @escaping @MainActor () -> Bool) {
        alertHostIsOnScreen = isOnScreen
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
    ///
    /// It asks nothing while another window's confirmation is up
    /// (`SettingsAppSignOutActivity.isConfirmationActiveInAnyWindow()`): two windows asking at
    /// once left the first alert up after the second one's sign-out. `evaluate` does not look
    /// at other windows. It judges the iOS switch, where that was never the case, and a
    /// request it passed over would wait for the next foregrounding.
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
                isRequestBeingHandled: isSigningOut || activity.isConfirmationActiveInAnyWindow(),
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
    ///
    /// The answer is for the session as it is when the question is asked, so that is kept
    /// with it (`asked`) and compared when the user answers (`signOutConfirmed`).
    private func presentConfirmation(account: SettingsAppSignOutAccount) {
        let asked = SettingsAppSignOutSubject(account)
        prompter.presentConfirmation(
            accountEmail: asked.email,
            onSignOut: { [weak self] in self?.signOutConfirmed(account: account, asked: asked) },
            onCancel: { [weak self] in self?.preferences.clearSignOutRequest() }
        )
    }

    /// The sign-out the Settings-app confirmation approved: the same
    /// `AuthSession.signOut()` the old in-app Settings screen called. It starts
    /// from UI, never from inside another auth transition (the auth gate is
    /// not reentrant).
    ///
    /// - Parameter asked: The session as it was when the confirmation was raised.
    private func signOutConfirmed(account: SettingsAppSignOutAccount, asked: SettingsAppSignOutSubject) {
        preferences.clearSignOutRequest()
        // The alert can outlive the session it was raised for (a sign-out from
        // elsewhere, or a restore whose credentials were rejected, finished
        // while it was up); once durably signed out there is no session left
        // for this switch to end — the same verdict the policy discards on.
        guard !account.isDurablySignedOut(), !isSigningOut else { return }
        // It can outlive it the other way too: a sign-in finished while it was up, and the
        // session there is now is not the one the user was asked about. That one is not
        // signed out on this answer. The user is told as for a sign-out that never started,
        // and asking again names the account that is signed in now.
        //
        // HONEST SCOPE: nobody has answered a stale confirmation in the app. The failure
        // alert is raised from inside the confirmation's own answer; if a window does not
        // show it there, the answer signs nothing out and says nothing.
        guard SettingsAppSignOutPolicy.answerStillApplies(
            asked: asked,
            current: SettingsAppSignOutSubject(account)
        ) else {
            Log.warning(
                "A sign-out confirmation was answered after the session it asked about had changed; nothing was signed out",
                category: .auth
            )
            presentFailure()
            return
        }
        // After the guards above, so a window is asked, and tells the user it refused, only
        // when there was a sign-out to refuse.
        guard !refusesConfirmedSignOut() else {
            Log.info("A confirmed sign-out was refused by its window; the account is still signed in", category: .auth)
            return
        }
        isSigningOut = true
        activity.signOutDidBegin()
        Task {
            let didSignOut = await account.signOut()
            isSigningOut = false
            activity.signOutDidEnd()
            if !didSignOut {
                // Cleanup never began (the reset marker could not be saved), so
                // the account is still signed in; say so rather than nothing.
                Log.error("Settings-app sign-out did not start; the account is still signed in", category: .auth)
                presentFailure()
            }
        }
    }

    /// Says a confirmed sign-out never started: in this controller's window, or, when that
    /// window is off screen, in the fallback window. With no fallback to take it, it is
    /// still raised here, and shows when the window is next opened.
    private func presentFailure() {
        if !alertHostIsOnScreen(), activity.showFailureInFallbackWindow() {
            return
        }
        prompter.presentFailure()
    }
}
