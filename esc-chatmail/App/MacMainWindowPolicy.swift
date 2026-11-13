import Foundation

/// The Mac's one mailbox window, and what closing it does (`docs/mac-app-plan.md`, decision 7:
/// closing the window quits the app).
///
/// SwiftUI quits an app whose only `Window` closes, and until the app had a second scene that
/// was the whole rule. With the Settings scene it is not enough. Measured in a stand-in program
/// on macOS 27.2 (2026-11-13), with one `Window` and one `Settings` scene:
/// - Settings never opened, or opened and closed again: closing the window quits, as before.
/// - Settings open: closing the window does not quit. The app runs on, with a Settings window
///   and no mailbox, until that window is closed too.
///
/// So the app quits itself when this window closes (`MacMainWindowCloseObserver`).
enum MacMainWindowPolicy {
    /// The `Window` scene's id, which AppKit gives its window as its identifier (measured in
    /// the same program: the window's `identifier` read `main`; `MacMainWindowCloseObserverTests`
    /// reads it from the app's own window in the Mac test host).
    static let windowID = "main"

    /// Whether closing the window with this identifier quits the app: the mailbox window
    /// only. A Settings window, a sheet, a Quick Look panel and an off-screen web view host
    /// all close without ending anything.
    static func closingQuitsApp(windowIdentifier: String?) -> Bool {
        windowIdentifier == windowID
    }
}
