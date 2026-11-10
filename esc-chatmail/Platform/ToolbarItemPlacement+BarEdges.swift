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

    /// The leading action of a view presented as a sheet (Cancel): `.topBarLeading` on iOS,
    /// unchanged; `.cancellationAction` on the Mac.
    ///
    /// A Mac sheet has no toolbar. An item placed at `.navigation` or `.primaryAction` inside
    /// one, which is what `leadingBarEdge` and `trailingBarEdge` give, is not drawn at all, so
    /// the sheet had no Cancel, Send or Done and could not be closed (measured on macOS 27.2,
    /// 2026-11-10; the Participants sheet trapped the window this way). The Mac draws the two
    /// action placements as buttons along the sheet's bottom edge, and Escape presses this one.
    static var sheetLeadingBarEdge: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .cancellationAction
        #endif
    }

    /// The trailing action of a view presented as a sheet (Done, Send): `.topBarTrailing` on
    /// iOS, unchanged; `.confirmationAction` on the Mac. See `sheetLeadingBarEdge`.
    ///
    /// On the Mac this makes the button the sheet's default button, which Return presses. Where
    /// that must not happen, give the button its own shortcut (`View.macSendKeyboardShortcut()`).
    static var sheetTrailingBarEdge: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .confirmationAction
        #endif
    }
}
