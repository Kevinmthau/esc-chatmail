#if os(macOS)
import SwiftUI

/// Puts a `MacSidebarListSelectionGuardView` in or behind a list, so the list stops drawing its
/// own selection. `MacConversationSidebar` has one behind its list, which is the one that turns
/// the selection off, before any row is selected. `MacSidebarRowSelectionBackground` carries
/// one behind the fill it draws for a selected row, for a list with none behind it.
struct MacSidebarListSelectionGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> MacSidebarListSelectionGuardView {
        MacSidebarListSelectionGuardView()
    }

    /// SwiftUI calls this inside its own update of the list, so the view only looks for the
    /// table here and writes nothing to it (`MacSidebarListSelectionGuardView.guardListTableView`).
    func updateNSView(_ view: MacSidebarListSelectionGuardView, context: Context) {
        view.guardListTableView()
    }
}
#endif
