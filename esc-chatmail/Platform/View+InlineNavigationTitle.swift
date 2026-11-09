import SwiftUI

extension View {
    /// Shows the navigation title inline in the navigation bar on iOS. The Mac has no large-title
    /// navigation bar to choose from (the title sits in the window's toolbar), so there it changes
    /// nothing.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
