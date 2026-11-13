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
}
#endif
