#if os(macOS)
import AppKit

/// Stops the list this view is inside drawing its own selection (`MacSidebarListSelectionGuard`).
///
/// The sidebar draws a selected row's fill itself (`MacSidebarRowSelectionPolicy`). Behind a
/// SwiftUI `List` on the Mac is an `NSTableView`, and it draws a selection of its own under
/// that fill: gray whenever the list does not have the keyboard focus. The fill has the same
/// shape, so it covers it, but only on a system whose table draws that shape, and the shape is
/// not something the app is told. It was measured, on one system. This view finds the table
/// whose row it is inside and sets its `selectionHighlightStyle` to `.none`, AppKit's setting
/// for a table that draws no selection. The rows are selected as before: the style changes what
/// the table draws, not what it selects.
///
/// Measured 2026-11-12 on macOS 27.2 in two throwaway programs, each an `.inset`
/// `List(selection:)` in a window that was never put on screen, not in the app:
/// - The list is an `NSTableView` (a `SwiftUIOutlineListView`), and a view in a row's
///   `listRowBackground` is inside it, four superviews down. The view is not inside it yet when
///   it joins its window or its superview: `layout()` is the call that found the table.
/// - With the style `.none` the list drew none of its gray selection, and none of its
///   accent-colored one with its rows marked emphasized, as AppKit marks them while the list has
///   the focus. A selection set from SwiftUI still reached the table's selected rows. The
///   separators next to a selected row stayed hidden, and the line between two selected rows
///   stayed, darker without the focus and lighter with it, as under the list's own selection.
/// - SwiftUI never set the style back: not when a row's content changed, the selection changed
///   or was emptied, every row was replaced, or the list was resized, scrolled, disabled, or
///   switched between light and dark. So this is an assignment, made again at each `layout()`
///   in case something does undo it, and not an observation as in `MacSidebarCollapseGuardView`.
///
/// The style is never set back to the table's own. The sidebar draws a fill for every selected
/// row for as long as the list lives, so the list has no selection of its own to go back to.
/// Until the first row is selected no fill exists and the table still has its own style, so
/// the table may draw that first selection for a frame before the fill arrives. That was not
/// measured. A click gives the list the focus, so the table would draw it in the accent color,
/// which is the fill's.
///
/// Not seen: the ring a table draws around a right-clicked row while its menu is open. Asking
/// the table for the row's menu drew no ring in the program with the style either way, so the
/// program cannot say whether `.none` changes it.
///
/// HONEST SCOPE: this depends on how SwiftUI builds a list on macOS 27.2, which is not API, and
/// nothing here was run on macOS 26, the oldest system the app runs on. If a system builds a
/// list another way, `guardedTableView` stays nil, the list goes on drawing its own selection,
/// and the fill covers it wherever the two have the same shape, which is what the sidebar had
/// before this view. `MacSidebarRowSelectionBackgroundTests` mounts a real list, so on the system
/// the Mac tests run on, a change in how a list is built fails a test.
final class MacSidebarListSelectionGuardView: NSView {
    /// The table whose own selection this view turned off, or nil while it is inside none.
    private(set) weak var guardedTableView: NSTableView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guardEnclosingTableView()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guardEnclosingTableView()
    }

    /// The call that found the table in the measurements.
    override func layout() {
        super.layout()
        guardEnclosingTableView()
    }

    /// The guard is not part of the interface. It has no size where the sidebar puts it, and
    /// this keeps a click from landing on it at any size.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Finds the table this view is inside and turns its own selection off.
    func guardEnclosingTableView() {
        let tableView = enclosingTableView()
        guardedTableView = tableView
        // Only a change is written: the setter redraws the table.
        if let tableView, tableView.selectionHighlightStyle != .none {
            tableView.selectionHighlightStyle = .none
        }
    }

    private func enclosingTableView() -> NSTableView? {
        var ancestor = superview
        while let view = ancestor {
            if let tableView = view as? NSTableView {
                return tableView
            }
            ancestor = view.superview
        }
        return nil
    }
}
#endif
