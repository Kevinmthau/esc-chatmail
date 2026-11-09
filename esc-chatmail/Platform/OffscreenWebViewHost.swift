#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import WebKit

/// Hosts `FullEmailWebViewManager`'s pre-rendering WebViews in a window the user never sees, so
/// WebKit actually lays out and paints content (a windowless WebView may defer rasterization until
/// first display, which would reintroduce a paint when adopted).
@MainActor
final class OffscreenWebViewHost {
    #if canImport(UIKit)
    private var window: UIWindow?

    func host(_ view: WKWebView, width: CGFloat) {
        guard let window = ensureWindow() else {
            return
        }
        view.frame = CGRect(
            origin: .zero,
            size: CGSize(width: width, height: window.bounds.height)
        )
        view.autoresizingMask = []
        window.rootViewController?.view.addSubview(view)
    }

    func remove(_ view: WKWebView) {
        view.removeFromSuperview()
    }

    func preferredHeight() -> CGFloat {
        ensureWindow()?.bounds.height ?? FullEmailWebViewMetrics.activeWindowScene()?.screen.bounds.height ?? 0
    }

    /// A window that is part of the active scene but positioned beyond the screen edge.
    private func ensureWindow() -> UIWindow? {
        if let window {
            return window
        }
        guard let scene = FullEmailWebViewMetrics.activeWindowScene() else {
            return nil
        }

        let screenBounds = scene.screen.bounds
        let window = UIWindow(windowScene: scene)
        // Positioned fully beyond the left edge: never visible to the user, but still part of the
        // scene so the render server composites it and WebKit paints the content.
        window.frame = CGRect(
            x: -screenBounds.width - 100,
            y: 0,
            width: screenBounds.width,
            height: screenBounds.height
        )
        window.windowLevel = UIWindow.Level.normal - 1
        window.isUserInteractionEnabled = false
        let rootViewController = UIViewController()
        rootViewController.view.backgroundColor = .clear
        window.rootViewController = rootViewController
        window.isHidden = false
        self.window = window
        return window
    }
    #elseif canImport(AppKit)
    private static let offscreenOrigin = NSPoint(x: -30_000, y: -30_000)
    /// Used only if the Mac reports no screen at all.
    private static let fallbackSize = NSSize(width: 1_440, height: 900)

    private var window: NSWindow?

    func host(_ view: WKWebView, width: CGFloat) {
        let window = ensureWindow()
        guard let contentView = window.contentView else {
            return
        }
        // A web view wider than the window would be clipped, so grow the window to fit. Mac
        // warm widths come from the reader, which is narrower than the screen, so this is rare.
        if width > contentView.bounds.width {
            window.setContentSize(NSSize(width: width, height: contentView.bounds.height))
        }
        view.frame = CGRect(
            origin: .zero,
            size: CGSize(width: width, height: contentView.bounds.height)
        )
        view.autoresizingMask = []
        contentView.addSubview(view)
    }

    func remove(_ view: WKWebView) {
        view.removeFromSuperview()
    }

    func preferredHeight() -> CGFloat {
        ensureWindow().contentView?.bounds.height ?? 0
    }

    /// A borderless window far off every screen that ignores the mouse and is never ordered in,
    /// so it never shows, takes focus, or appears in the Window menu.
    ///
    /// To macOS a window off every screen is not visible, so WebKit reports the warm page as
    /// `hidden` until it is adopted. The WebKit spike found that warming still completes (50–160
    /// ms) and `finalizeWarm`'s snapshot still returns; whether the first frame after adoption
    /// flashes is still to be checked in a real launch.
    private func ensureWindow() -> NSWindow {
        if let window {
            return window
        }

        let screenSize = (NSScreen.main ?? NSScreen.screens.first)?.frame.size ?? Self.fallbackSize
        let window = NSWindow(
            contentRect: NSRect(origin: Self.offscreenOrigin, size: screenSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        self.window = window
        return window
    }
    #endif
}
