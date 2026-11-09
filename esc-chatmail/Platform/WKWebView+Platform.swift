#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import WebKit

/// The `WKWebView` settings whose API differs between UIKit and AppKit, each written once for both
/// platforms. On iOS every member does exactly what the shared code did inline before the Mac
/// port. The Mac column of the "Mac equivalents" table in `docs/mac-app-plan.md` (PR E) records
/// what the WebKit spike checked.
///
/// Turning off input on a display-only web view is not here: on the Mac it needs a `hitTest(_:)`
/// override, so it lives on `LayoutAwareWKWebView.makeNonInteractive()`.
extension WKWebView {
    /// Forces the web view light or dark, or lets it follow its surroundings. CSS
    /// `prefers-color-scheme` follows on both platforms.
    func applyInterfaceStyle(_ style: PlatformInterfaceStyle) {
        #if canImport(UIKit)
        overrideUserInterfaceStyle = style
        #elseif canImport(AppKit)
        appearance = style.appearance
        #endif
    }

    /// Paints `color` behind the page and in the overscroll area.
    ///
    /// On iOS the view is also made non-opaque, so `.clear` shows whatever is behind it. On the
    /// Mac only `underPageBackgroundColor` is set: the page itself stays opaque white, because
    /// only the private `drawsBackground` key makes a Mac web view see-through, and the app
    /// avoids private API. That costs nothing today: the HTML wrapper paints a theme color over
    /// every preview and the full reader, and the one see-through case (`BaseEmailWebView`'s
    /// `.simplePreview` with no `isDarkMode`) has no caller, since compose passes its theme.
    func applyNativeBackgroundColor(_ color: PlatformColor) {
        #if canImport(UIKit)
        isOpaque = false
        backgroundColor = color
        scrollView.backgroundColor = color
        underPageBackgroundColor = color
        #elseif canImport(AppKit)
        underPageBackgroundColor = color
        #endif
    }

    /// The full reader's insets, matching Apple Mail on iOS: content insets never adjust for the
    /// safe area, while scroll indicators still do. Nothing on the Mac, where the Phase 1 window
    /// puts no bars over the reader. If the reader later sits under a transparent toolbar, the
    /// Mac equivalent is `obscuredContentInsets` (macOS 26).
    func applyFullReaderScrollInsets() {
        #if canImport(UIKit)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.automaticallyAdjustsScrollIndicatorInsets = true
        #endif
    }

    /// Scrolls the page back to its top-left corner without animation. On the Mac, where a web
    /// view has no `scrollView`, a script does it; `evaluateJavaScript` runs even with page
    /// JavaScript turned off.
    func resetScrollPosition() {
        #if canImport(UIKit)
        scrollView.setContentOffset(.zero, animated: false)
        #elseif canImport(AppKit)
        evaluateJavaScript("window.scrollTo(0, 0)", completionHandler: nil)
        #endif
    }

    #if !canImport(UIKit) && canImport(AppKit)
    /// As `UIView.layoutIfNeeded()`: lays out the view and its subviews now if they need it.
    func layoutIfNeeded() {
        layoutSubtreeIfNeeded()
    }
    #endif
}
