#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Finds the `PresentationAnchor` the sign-in screen hands to `AuthSession.signIn(presenting:)`.
@MainActor
enum PresentationAnchorLookup {
    /// The anchor to present sign-in from, or nil when the app has no window yet.
    ///
    /// iOS: the first scene's first window's root view controller, the lookup `SignInView` has
    /// always made. The Mac: the key window, else the main window, else the first visible one.
    static func signInAnchor() -> PresentationAnchor? {
        #if canImport(UIKit)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return nil
        }
        return windowScene.windows.first?.rootViewController
        #else
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first(where: \.isVisible)
        #endif
    }
}
