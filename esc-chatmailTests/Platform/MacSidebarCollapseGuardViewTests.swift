#if os(macOS)
import AppKit
import XCTest
@testable import esc_chatmail

/// The view that stops the Mac mailbox's sidebar being closed. These run in `Mac.xctestplan`
/// only: the view is AppKit.
///
/// HONEST SCOPE: the split view here is built by hand from AppKit's own classes. That pins what
/// the guard does to an `NSSplitViewItem` it sits in. It does not pin that SwiftUI's
/// `NavigationSplitView` is such a split view with the sidebar's content inside one of its
/// items, that SwiftUI turns `canCollapse` back on, or that AppKit then stops the divider at the
/// column's minimum width. Those were measured in a throwaway program, not in the app
/// (`MacSidebarCollapseGuardView`).
@MainActor
final class MacSidebarCollapseGuardViewTests: XCTestCase {
    /// A sidebar's item is made collapsible by AppKit, and a drag of the divider past the
    /// column's minimum width then closes it.
    ///
    /// Revert-check: deleting `item.canCollapse = false` from the observation's handler in
    /// `MacSidebarCollapseGuardView.guardEnclosingSplitViewItem` makes this fail.
    func testGuard_insideTheSidebarItem_turnsOffCollapsing() {
        let split = makeSplit()
        XCTAssertTrue(split.sidebar.canCollapse, "AppKit makes a sidebar collapsible")
        XCTAssertTrue(split.sidebar.canCollapseFromWindowResize)
        let guardView = MacSidebarCollapseGuardView()

        split.sidebar.viewController.view.addSubview(guardView)

        XCTAssertTrue(guardView.guardedItem === split.sidebar)
        XCTAssertFalse(split.sidebar.canCollapse)
        XCTAssertFalse(split.sidebar.canCollapseFromWindowResize, "AppKit turns this off with canCollapse")
    }

    /// SwiftUI turned `canCollapse` back on at every state change of the split view's content,
    /// so one assignment when the guard attaches does not last.
    ///
    /// Revert-check: replacing the observation in
    /// `MacSidebarCollapseGuardView.guardEnclosingSplitViewItem` with a single
    /// `item?.canCollapse = false` makes this fail.
    func testGuard_canCollapseTurnedBackOn_turnsItOffAgain() {
        let split = makeSplit()
        let guardView = MacSidebarCollapseGuardView()
        split.sidebar.viewController.view.addSubview(guardView)

        split.sidebar.canCollapse = true
        XCTAssertFalse(split.sidebar.canCollapse)

        split.sidebar.canCollapse = true
        XCTAssertFalse(split.sidebar.canCollapse, "and every time after the first")
    }

    /// The guard holds the item it is inside, not the split view's first item or all of them.
    ///
    /// Revert-check: returning `controller.splitViewItems.first` from
    /// `MacSidebarCollapseGuardView.enclosingSplitViewItem` makes this fail.
    func testGuard_insideAnotherCollapsibleItem_leavesTheSidebarCollapsible() {
        let split = makeSplit()
        XCTAssertTrue(split.inspector.canCollapse, "AppKit makes an inspector collapsible too")
        let guardView = MacSidebarCollapseGuardView()

        split.inspector.viewController.view.addSubview(guardView)

        XCTAssertTrue(guardView.guardedItem === split.inspector)
        XCTAssertFalse(split.inspector.canCollapse)
        XCTAssertTrue(split.sidebar.canCollapse)
    }

    func testGuard_outsideASplitView_guardsNothing() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let guardView = MacSidebarCollapseGuardView()

        container.addSubview(guardView)
        guardView.guardEnclosingSplitViewItem()

        XCTAssertNil(guardView.guardedItem)
    }

    /// A guard that kept observing an item it had left would go on overriding a split view it
    /// no longer belongs to.
    ///
    /// Revert-check: returning early from `guardEnclosingSplitViewItem` when
    /// `enclosingSplitViewItem()` is nil makes this fail.
    func testGuard_removedFromItsItem_stopsHoldingIt() {
        let split = makeSplit()
        let guardView = MacSidebarCollapseGuardView()
        split.sidebar.viewController.view.addSubview(guardView)
        XCTAssertFalse(split.sidebar.canCollapse)

        guardView.removeFromSuperview()

        XCTAssertNil(guardView.guardedItem)
        split.sidebar.canCollapse = true
        XCTAssertTrue(split.sidebar.canCollapse)
    }

    // MARK: - Helpers

    private struct Split {
        /// Held so the items stay in a live split view for the length of the test.
        let controller: NSSplitViewController
        let sidebar: NSSplitViewItem
        let inspector: NSSplitViewItem
    }

    /// A split view of a sidebar, a content column and an inspector, with its views loaded. It
    /// is in no window: the guard reads the view hierarchy, not the screen.
    private func makeSplit() -> Split {
        let controller = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: makeColumnController())
        let content = NSSplitViewItem(viewController: makeColumnController())
        let inspector = NSSplitViewItem(inspectorWithViewController: makeColumnController())
        controller.addSplitViewItem(sidebar)
        controller.addSplitViewItem(content)
        controller.addSplitViewItem(inspector)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        return Split(controller: controller, sidebar: sidebar, inspector: inspector)
    }

    private func makeColumnController() -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        return controller
    }
}
#endif
