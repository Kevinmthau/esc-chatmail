import SwiftUI
import UIKit
import XCTest

extension XCTestCase {
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
}
