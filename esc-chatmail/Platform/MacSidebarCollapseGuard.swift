#if os(macOS)
import SwiftUI

/// Puts a `MacSidebarCollapseGuardView` in a split view column, so the user cannot close that
/// column. Applied with `View.macSplitViewColumnCannotCollapse()`.
struct MacSidebarCollapseGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> MacSidebarCollapseGuardView {
        MacSidebarCollapseGuardView()
    }

    func updateNSView(_ view: MacSidebarCollapseGuardView, context: Context) {
        view.guardEnclosingSplitViewItem()
    }
}

extension View {
    /// Stops the user closing the `NavigationSplitView` column this view is the content of: the
    /// divider stops at the column's minimum width (`MacSidebarCollapseGuardView`).
    ///
    /// The guard is an empty view of no size behind the content. It draws nothing and takes no
    /// clicks, and it is hidden from accessibility because it is not part of the interface.
    func macSplitViewColumnCannotCollapse() -> some View {
        background {
            MacSidebarCollapseGuard()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
#endif
