#if canImport(UIKit)
import UIKit
#else
import CoreGraphics
#endif

/// The key window's safe-area insets, read outside SwiftUI's layout.
@MainActor
enum KeyWindowSafeArea {
    /// The bottom safe-area inset of the active scene's key window (the home indicator), which
    /// the chat transcript subtracts from the keyboard's height (`KeyboardResponder`).
    ///
    /// Always 0 on the Mac: a window has no home indicator, and there is no on-screen keyboard
    /// for the value to be subtracted from.
    static var bottomInset: CGFloat {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = activeScene?.windows.first { $0.isKeyWindow } ?? activeScene?.windows.first
        return window?.safeAreaInsets.bottom ?? 0
        #else
        0
        #endif
    }
}
