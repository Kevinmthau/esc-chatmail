#if os(macOS)
import AppKit

/// Stops the user closing the split view column this view sits in (`MacSidebarCollapseGuard`).
///
/// Behind a `NavigationSplitView` is an `NSSplitView` whose delegate is an
/// `NSSplitViewController`, and the sidebar is one of its `NSSplitViewItem`s with `canCollapse`
/// on, which is AppKit's permission for the user to close it by dragging or double-clicking the
/// divider. SwiftUI has no setting for that. This view finds the item whose view it is inside and
/// turns `canCollapse` off, and for a sidebar AppKit turns `canCollapseFromWindowResize` off with
/// it. The divider then stops at the column's minimum width.
///
/// It holds `canCollapse` off with an observation, not one assignment, because SwiftUI turns it
/// back on.
///
/// Measured 2026-11-11 on macOS 27.2 in a throwaway SwiftUI program with a `Window` scene and a
/// sidebar carrying the app's modifiers, not in the app. The divider was dragged from 320 points
/// to 40 points past the window's leading edge with mouse events 16 ms apart, twice:
/// - With this view in the sidebar, the sidebar never closed and the split view's visibility
///   binding was never written. The divider stopped at the 260-point minimum, and the window
///   kept its width.
/// - SwiftUI set `canCollapse` back to true at each of six state changes of the split view's
///   content, and after each write of the visibility binding. The observation turned it off
///   again every time. One assignment at attach did not last.
/// - `NSSplitViewController.toggleSidebar(_:)` did nothing while `canCollapse` was off.
/// - Setting the item's `isCollapsed` directly still closes it: AppKit always allows that. The
///   binding then reports it, which is what `MacSidebarVisibilityPolicy` is still for.
///
/// HONEST SCOPE: this depends on how SwiftUI builds a split view on macOS 27.2, which is not
/// API. If a later system builds it another way, `guardedItem` stays nil, nothing here runs, and
/// the visibility reset in `MacMailboxView` is what keeps the sidebar on screen.
final class MacSidebarCollapseGuardView: NSView {
    /// The split view item being held open, or nil while this view is in none.
    private(set) weak var guardedItem: NSSplitViewItem?
    private var canCollapseObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guardEnclosingSplitViewItem()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guardEnclosingSplitViewItem()
    }

    /// The call that found the item in the measurements: SwiftUI had not put the column's views
    /// inside the split view yet when this view first joined the window.
    override func layout() {
        super.layout()
        guardEnclosingSplitViewItem()
    }

    /// Finds the split view item this view is inside and holds its `canCollapse` off. Does
    /// nothing when that item is already the guarded one.
    func guardEnclosingSplitViewItem() {
        let item = enclosingSplitViewItem()
        guard item !== guardedItem else { return }
        // An item this view has left is no longer held. It keeps the value it has; SwiftUI sets
        // its own again at the next update.
        canCollapseObservation = nil
        guardedItem = item
        // `.initial` runs the handler once now, which is the first turning off.
        canCollapseObservation = item?.observe(\.canCollapse, options: [.initial]) { item, _ in
            // KVO runs this inside the setter, on the setter's thread. AppKit and SwiftUI set
            // the property on the main thread; anything else is not theirs and is left alone.
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                // Only a true is answered, so the assignment below does not come back here.
                if item.canCollapse {
                    item.canCollapse = false
                }
            }
        }
    }

    /// The item of the nearest enclosing `NSSplitViewController` whose view this view is inside.
    private func enclosingSplitViewItem() -> NSSplitViewItem? {
        var ancestor = superview
        while let view = ancestor {
            if let splitView = view as? NSSplitView,
               let controller = splitView.delegate as? NSSplitViewController {
                return controller.splitViewItems.first { isDescendant(of: $0.viewController.view) }
            }
            ancestor = view.superview
        }
        return nil
    }
}
#endif
