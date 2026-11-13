#if os(macOS)
import AppKit
import XCTest
@testable import esc_chatmail

/// `MacWindowVisibilityProbe.isOnScreen(windowOf:)`: whether a view's window is on screen at
/// the moment it is asked.
///
/// HONEST SCOPE: the window here is borderless and off every screen, ordered in for one
/// test so that AppKit counts it visible. Nobody has closed the app's Settings window with
/// its sign-out running, and what SwiftUI does with that window's views when it closes was
/// not measured: the probe answers off screen whether the view keeps a closed window or
/// loses its window.
@MainActor
final class MacWindowVisibilityProbeTests: XCTestCase {
    /// Revert-check: making the closure `MacWindowVisibilityProbe.isOnScreen(windowOf:)`
    /// returns answer false makes this fail: a failure of a sign-out started in the Settings
    /// window would always go to the mailbox window, under the Settings window that asked.
    func testIsOnScreen_windowOrderedIn_isTrue() throws {
        let window = try makeTestHostWindow()
        let view = NSView()
        window.contentView = view
        let isOnScreen = MacWindowVisibilityProbe.isOnScreen(windowOf: view)
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            window.close()
        }

        XCTAssertTrue(isOnScreen())
    }

    /// Closing a window orders it out; the view stays in it.
    ///
    /// Revert-check: answering `view?.window != nil` from the closure
    /// `MacWindowVisibilityProbe.isOnScreen(windowOf:)` returns makes this fail: the failure
    /// would be raised on a closed Settings window and wait there unseen.
    func testIsOnScreen_windowClosed_isFalse() throws {
        let window = try makeTestHostWindow()
        let view = NSView()
        window.contentView = view
        let isOnScreen = MacWindowVisibilityProbe.isOnScreen(windowOf: view)
        window.orderFront(nil)
        XCTAssertTrue(isOnScreen())

        window.close()

        XCTAssertFalse(isOnScreen())
        XCTAssertNotNil(view.window, "the view is still in the closed window")
    }

    func testIsOnScreen_viewInNoWindow_isFalse() {
        let view = NSView()

        XCTAssertFalse(MacWindowVisibilityProbe.isOnScreen(windowOf: view)())
    }

    /// The closure must not keep the view: it is kept by the sign-out controller, which can
    /// outlive the window's views.
    ///
    /// Revert-check: capturing `view` strongly in `MacWindowVisibilityProbe.isOnScreen(windowOf:)`
    /// makes this fail.
    func testIsOnScreen_viewReleased_isFalseAndViewIsNotKept() {
        weak var weakView: NSView?
        var isOnScreen: (@MainActor () -> Bool)?
        autoreleasepool {
            let view = NSView()
            weakView = view
            isOnScreen = MacWindowVisibilityProbe.isOnScreen(windowOf: view)
        }

        XCTAssertNil(weakView)
        XCTAssertEqual(isOnScreen?(), false)
    }
}
#endif
