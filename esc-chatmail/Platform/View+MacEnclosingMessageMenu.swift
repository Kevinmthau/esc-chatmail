import SwiftUI

extension View {
    /// Hands a message's menu entries to the views inside its row whose own context menus
    /// replace the row's on the Mac (`MacEnclosingMessageMenu`). Nothing on iOS, where the
    /// view is returned as it is: a long press there opens the row's menu wherever it lands.
    ///
    /// - Parameter entries: What the row's own `contextMenu` is given.
    @ViewBuilder
    func macEnclosingMessageMenu<Entries: View>(
        @ViewBuilder _ entries: @escaping () -> Entries
    ) -> some View {
        #if os(macOS)
        environment(\.macEnclosingMessageMenu, MacEnclosingMessageMenu { AnyView(entries()) })
        #else
        self
        #endif
    }
}
