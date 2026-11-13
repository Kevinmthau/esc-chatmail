#if os(macOS)
import AppKit

/// Whether the mailbox window has a sheet attached, whichever window has the focus, read
/// from AppKit at the moment it is asked.
///
/// `FocusedWindowSheet` answers for the window a command acts on. That is not enough for Sign
/// Out…, which the Settings window asks for too (`MacSettingsView`): with Settings in front
/// the key and main windows are both the Settings window, and a sheet on the mailbox window
/// behind it went unseen. Confirmed there, the sign-out took the mailbox away with New Message
/// still open on it, and the typed message with it, with none of the questions closing that
/// sheet asks (`ComposeCancelPolicy`). So `SignOutMenuAction.perform()` asks this as well.
///
/// Asked when Sign Out… is chosen, it is not enough for the Settings window either. That
/// window's confirmation is a sheet on the Settings window only, so the mailbox window still
/// takes clicks while it is up: New Message could be opened and typed in after the question
/// was asked, and the answer then took it away. The Settings window's controller therefore
/// asks again when the user answers Sign Out (`refusesSignOutConfirmedElsewhere()`). The
/// mailbox window's controller must not: its own confirmation is the sheet on the mailbox
/// window, and it would refuse every sign-out it confirmed.
///
/// Like `FocusedWindowSheet`, the answer is never stored or counted, so it cannot stay true
/// after the sheet has gone.
@MainActor
enum MailboxWindowSheet {
    static var isAttached: Bool {
        isAttached(among: NSApplication.shared.windows)
    }

    /// `windows` is the app's windows; the tests give their own.
    static func isAttached(among windows: [NSWindow]) -> Bool {
        windows.contains { window in
            MacMainWindowPolicy.isMailboxWindow(windowIdentifier: window.identifier?.rawValue)
                && window.attachedSheet != nil
        }
    }

    /// Whether a sign-out confirmed in another window is refused because the mailbox window
    /// has a sheet attached now. It beeps when it refuses, as Sign Out… does when it is
    /// chosen under a sheet, so the answer does not look ignored.
    ///
    /// HONEST SCOPE: nobody has answered the Settings window's confirmation with New Message
    /// open on the mailbox window. The beep says nothing of why; the account stays signed in
    /// and the Settings window shows it.
    static func refusesSignOutConfirmedElsewhere() -> Bool {
        refusesSignOutConfirmedElsewhere(among: NSApplication.shared.windows, beep: { NSSound.beep() })
    }

    /// `windows` is the app's windows and `beep` its beep; the tests give their own.
    static func refusesSignOutConfirmedElsewhere(among windows: [NSWindow], beep: () -> Void) -> Bool {
        guard isAttached(among: windows) else { return false }
        beep()
        return true
    }
}
#endif
