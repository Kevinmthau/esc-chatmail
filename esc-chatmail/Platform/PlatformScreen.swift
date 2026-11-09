#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The display's pixels per point, for sizing decoded bitmaps to what the screen can show, and
/// the screen width that screen-relative bubble widths are a fraction of.
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

    /// The width, in points, that caps bubble widths as a fraction of the screen
    /// (`MessageBubbleStyle.maxBubbleWidth`, `ImageAttachmentBubble`).
    ///
    /// `UIScreen.main.bounds.width` on iOS, so every iPhone keeps its bubble widths. On the Mac,
    /// the main screen's width, else the narrowest current Mac display's (1280 points) when no
    /// screen is attached. Every Mac screen is wider than those fractions' fixed caps (320 and
    /// 280 points), so on the Mac the caps decide, whatever size the window is.
    static var width: CGFloat {
        #if canImport(UIKit)
        UIScreen.main.bounds.width
        #else
        NSScreen.main?.frame.width ?? 1280
        #endif
    }
}
