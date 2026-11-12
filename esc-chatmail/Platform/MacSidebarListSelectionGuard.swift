#if os(macOS)
import SwiftUI

/// Puts a `MacSidebarListSelectionGuardView` in a list row, so the list stops drawing its own
/// selection. `MacSidebarRowSelectionBackground` carries one behind the fill it draws for a
/// selected row.
struct MacSidebarListSelectionGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> MacSidebarListSelectionGuardView {
        MacSidebarListSelectionGuardView()
    }

    func updateNSView(_ view: MacSidebarListSelectionGuardView, context: Context) {
        view.guardEnclosingTableView()
    }
}
#endif
