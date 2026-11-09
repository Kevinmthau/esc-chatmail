import SwiftUI

extension ToolbarItemPlacement {
    /// The leading edge of the bar: `.topBarLeading` on iOS, unchanged from before the Mac port;
    /// `.navigation`, the toolbar's leading edge, on the Mac, where `.topBarLeading` does not exist.
    static var leadingBarEdge: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// The trailing edge of the bar: `.topBarTrailing` on iOS (what `.navigationBarTrailing`, its
    /// deprecated spelling, also means), unchanged from before the Mac port; `.primaryAction` on
    /// the Mac, where neither exists. iOS keeps its own placement rather than `.primaryAction` so
    /// its toolbar grouping and styling stay exactly as they were.
    static var trailingBarEdge: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}
