import Foundation

/// Decides whether the Mac's Sign Out… menu command (`SignOutCommands`) can be chosen, and what
/// choosing it does.
enum SignOutMenuPolicy {
    /// What choosing the command does.
    enum Choice: Equatable {
        /// Ask the user to confirm signing out.
        case confirm
        /// Ask nothing. The command beeps, so the choice does not look ignored.
        case refuse
    }

    /// - Signed in → enabled. That includes a session waiting on reauthentication, which keeps
    ///   `isAuthenticated` true and is still an account on this Mac.
    /// - Not signed in, but an account is still held on this Mac → enabled. A launch restore that
    ///   failed retryably leaves the credentials, the store and the body files behind
    ///   `SignInView`, and iOS can sign that state out from its Settings switch
    ///   (`SettingsAppSignOutPolicy`). `holdsAccountWhileSignedOut` is a cached answer
    ///   (`SettingsAppSignOutController.refreshHeldAccount`), because the live one reads the
    ///   keychain and this runs in a view body. It may be stale: `choice` judges the fresh
    ///   answer, so a command enabled for an account that has since gone asks nothing.
    /// - Nobody signed in and nothing held → disabled: there is no session to end.
    /// - A confirmed sign-out already running → disabled, so the command reads as busy.
    static func isEnabled(isAuthenticated: Bool, holdsAccountWhileSignedOut: Bool, isSigningOut: Bool) -> Bool {
        (isAuthenticated || holdsAccountWhileSignedOut) && !isSigningOut
    }

    /// - The focused window has a sheet attached → refuse. The confirmation is an alert on that
    ///   window, and a Mac window shows one sheet at a time: raised under New Message or the
    ///   reader it would stay queued, unseen, until that sheet closed, and then appear with
    ///   nothing on screen to explain it. `focusedWindowHasSheet` is read from AppKit at the
    ///   moment the command is chosen (`FocusedWindowSheet`). It must stay a live read and never
    ///   become a count of the sheets the app presented: a count that stuck above zero would
    ///   disable the Mac's only way to sign out.
    /// - `SettingsAppSignOutPolicy` would not ask now (no account left to sign out, or a
    ///   request already being handled) → refuse.
    /// - Otherwise → confirm.
    static func choice(focusedWindowHasSheet: Bool, decision: SettingsAppSignOutPolicy.Decision) -> Choice {
        guard !focusedWindowHasSheet, decision == .confirm else { return .refuse }
        return .confirm
    }
}
