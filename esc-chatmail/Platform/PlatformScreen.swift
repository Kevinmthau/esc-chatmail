#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The display's pixels per point, for sizing decoded bitmaps to what the screen can show.
@MainActor
enum PlatformScreen {
    /// `UIScreen.main.scale` on iOS. On the Mac, the highest scale among the connected screens, so
    /// an image stays sharp when its window moves onto a Retina display; 2, the scale of every
    /// current Mac's built-in display, when no screen is attached.
    static var scale: CGFloat {
        #if canImport(UIKit)
        UIScreen.main.scale
        #else
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        #endif
    }
}
