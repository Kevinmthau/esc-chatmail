import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import XCTest

extension XCTestCase {
    #if os(iOS)
    /// A new window on the test host app's window scene.
    @MainActor
    func makeTestHostWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "The test host app has no window scene"
        )
        return UIWindow(windowScene: scene)
    }

    /// Mounts `rootView` in a shown window on the test host's window scene, laid out once,
    /// and hides the window at teardown. The window's safe area is left out of the hosting
    /// controller, so `sizeThatFits(in:)` measures the view alone.
    @MainActor
    func mountInTestWindow<Content: View>(_ rootView: Content) throws -> UIHostingController<Content> {
        let host = UIHostingController(rootView: rootView)
        host.safeAreaRegions = []
        let window = try makeTestHostWindow()
        window.rootViewController = host
        window.isHidden = false
        addTeardownBlock { @MainActor in
            window.isHidden = true
        }
        host.view.layoutIfNeeded()
        return host
    }
    #elseif os(macOS)
    /// A new borderless window off every screen, never ordered in, so a Mac test run puts
    /// nothing on the screen. Views in it still lay out, and SwiftUI still builds its AppKit
    /// views; the full reader's warm pool uses the same kind of window (`OffscreenWebViewHost`).
    /// Close it when done: it is not released on close, so the caller's reference stays valid.
    @MainActor
    func makeTestHostWindow() throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 390, height: 844),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// Mounts `rootView` as the content of a window from `makeTestHostWindow()`, laid out once,
    /// and closes the window at teardown.
    @MainActor
    func mountInTestWindow<Content: View>(_ rootView: Content) throws -> NSHostingController<Content> {
        let host = NSHostingController(rootView: rootView)
        let window = try makeTestHostWindow()
        window.contentViewController = host
        addTeardownBlock { @MainActor in
            window.close()
        }
        host.view.layoutSubtreeIfNeeded()
        return host
    }
    #endif
}
