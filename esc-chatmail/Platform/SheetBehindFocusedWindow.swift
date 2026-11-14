#if os(macOS)
import AppKit

/// The window whose sheet a refused Sign Out… is waiting on, when that window is not the one
/// in front, and bringing it there.
///
/// Sign Out… asks nothing while the mailbox window has a sheet attached, or while the other
/// window's confirmation is up (`SignOutMenuAction.perform`), and beeps. In both cases what
/// is in the way is a sheet on a window the command was not chosen in, and that window can
/// be behind the one in front: with the Settings window's confirmation up and the mailbox
/// window over it, Sign Out… beeped every time it was chosen, with nothing on screen to say
/// why. So a refusal also brings that window forward, and its sheet with it.
///
/// Nothing is brought forward while the focused window has a sheet itself: what is in the
/// way is then already in front (`FocusedWindowSheet`).
///
/// HONEST SCOPE: which window is found is pinned with stand-in windows
/// (`SheetBehindFocusedWindowTests`). No window has been brought forward in the app.
@MainActor
enum SheetBehindFocusedWindow {
    /// Brings the window found by `window(among:keyWindow:mainWindow:)` to the front, if
    /// there is one.
    static func reveal() {
        let application = NSApplication.shared
        reveal(
            among: application.windows,
            keyWindow: application.keyWindow,
            mainWindow: application.mainWindow,
            bringForward: { window in
                // A miniaturized window is not on screen for `makeKeyAndOrderFront` to raise.
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
            }
        )
    }

    /// `windows`, `keyWindow` and `mainWindow` are the app's, and `bringForward` raises a
    /// window; the tests give their own.
    static func reveal(
        among windows: [NSWindow],
        keyWindow: NSWindow?,
        mainWindow: NSWindow?,
        bringForward: (NSWindow) -> Void
    ) {
        guard let behind = window(among: windows, keyWindow: keyWindow, mainWindow: mainWindow) else { return }
        bringForward(behind)
    }

    /// A window with a sheet attached that is not the focused window, or nil when the focused
    /// window has a sheet itself or no window has one.
    static func window(among windows: [NSWindow], keyWindow: NSWindow?, mainWindow: NSWindow?) -> NSWindow? {
        guard !FocusedWindowSheet.isAttached(keyWindow: keyWindow, mainWindow: mainWindow) else { return nil }
        return windows.first { $0.attachedSheet != nil }
    }
}
#endif
