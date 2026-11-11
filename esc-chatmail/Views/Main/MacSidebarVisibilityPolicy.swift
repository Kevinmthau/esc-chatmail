import SwiftUI

/// Keeps the Mac mailbox's sidebar on screen (`MacMailboxView`).
///
/// The window has no Hide Sidebar button (`.toolbar(removing: .sidebarToggle)`) and no menu
/// command for the sidebar, because the sidebar is the only place to pick a chat. Removing the
/// button does not stop the sidebar closing: dragging its divider to the window's leading edge
/// still closes it, and then nothing in the window brings it back.
///
/// So the split view's column visibility is state the view owns, and when the split view reports
/// the sidebar closed, the view puts both columns back.
///
/// Measured 2026-11-11 in a throwaway off-screen program on macOS 27.2, not in the app, with a
/// mouse drag of the divider sent to the split view:
/// - With no visibility binding, the drag closed the sidebar and it stayed closed.
/// - `NavigationSplitView(columnVisibility: .constant(.all))` did not hold it open. It closed and
///   stayed closed. A binding that refuses the write is no fix: the state has to change and
///   change back.
/// - A binding the split view can write reported `.detailOnly`. Set back to `.all`, the sidebar
///   reopened. During one drag held past the edge it closed and reopened four times, and it was
///   open when the drag ended.
enum MacSidebarVisibilityPolicy {
    /// The visibility to set when the split view reports `reported`, or nil when the sidebar is
    /// showing and there is nothing to set.
    ///
    /// `.detailOnly` is what the split view reported for a sidebar dragged closed. `.all` and
    /// `.doubleColumn` both show the sidebar of a two-column split view.
    ///
    /// `.automatic` is whatever the platform makes of it, and the comparison below follows
    /// that: on an iPhone simulator it compares equal to `.detailOnly`, and on macOS 27.2 to
    /// neither `.detailOnly` nor `.all` (both seen 2026-11-11). The Mac's split view never
    /// reported it in the measurements above.
    static func correction(for reported: NavigationSplitViewVisibility) -> NavigationSplitViewVisibility? {
        reported == .detailOnly ? .all : nil
    }
}
