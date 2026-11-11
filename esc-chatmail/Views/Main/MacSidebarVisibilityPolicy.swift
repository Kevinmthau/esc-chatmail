import SwiftUI

/// Puts the Mac mailbox's sidebar back when it has been closed (`MacMailboxView`).
///
/// The window has no Hide Sidebar button (`.toolbar(removing: .sidebarToggle)`) and no menu
/// command for the sidebar, because the sidebar is the only place to pick a chat. Removing the
/// button does not stop the sidebar closing: dragging its divider to the window's leading edge
/// still closed it, and then nothing in the window brought it back.
///
/// What stops that drag is `MacSidebarCollapseGuardView`. This is the fallback behind it: the
/// split view's column visibility is state the view owns, and when the split view reports the
/// sidebar closed, the view puts both columns back. It stays because the guard depends on how
/// SwiftUI builds a split view, and because AppKit can still be told in code to close the
/// sidebar. It is not enough by itself: see the second set of measurements.
///
/// Measured 2026-11-11 in a throwaway off-screen program on macOS 27.2, not in the app, with a
/// mouse drag of the divider sent to the split view:
/// - With no visibility binding, the drag closed the sidebar and it stayed closed.
/// - `NavigationSplitView(columnVisibility: .constant(.all))` did not hold it open. It closed and
///   stayed closed. A binding that refuses the write is no fix: the state has to change and
///   change back.
/// - A binding the split view can write reported `.detailOnly`. Set back to `.all`, the sidebar
///   reopened, and it was open when the drag ended.
///
/// Measured the same day in a second throwaway program, with a `Window` scene and the drag's
/// mouse events 16 ms apart:
/// - Left to this reset alone, the sidebar closed and reopened 69 times over two drags of 70
///   and 30 events: once a drag had gone far enough to close it, nearly every further event
///   closed it again. The window ended 320 points wider, because AppKit widens the window when
///   it reopens a sidebar.
/// - A sidebar closed in code (`NSSplitViewItem.isCollapsed`) was reported as `.detailOnly` too,
///   and the reset reopened it.
/// - A launch whose saved split view frames had the sidebar closed opened it without reporting
///   anything: the state starts at `.all`, and SwiftUI applies it. Nothing needs checking at
///   launch.
enum MacSidebarVisibilityPolicy {
    /// The visibility to set when the split view reports `reported`, or nil when the sidebar is
    /// showing and there is nothing to set.
    ///
    /// `.detailOnly` is what the split view reported for a sidebar dragged closed. `.all` and
    /// `.doubleColumn` both show the sidebar of a two-column split view.
    ///
    /// `.automatic` is whatever the platform makes of it, and the comparison below follows
    /// that: on an iPhone simulator it compares equal to `.detailOnly`, and on macOS 27.2 to
    /// `.doubleColumn` (both seen 2026-11-11). So on the Mac `.detailOnly` is the only one of
    /// the four values that does not show the sidebar, and a rule that corrected every value
    /// but `.all` and `.doubleColumn` would be this rule. The Mac's split view never reported
    /// `.automatic` in the measurements above.
    static func correction(for reported: NavigationSplitViewVisibility) -> NavigationSplitViewVisibility? {
        reported == .detailOnly ? .all : nil
    }
}
