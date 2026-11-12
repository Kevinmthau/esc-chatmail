#if os(macOS)
import SwiftUI
import AppKit

/// The fill the Mac sidebar draws behind a selected row (`MacConversationSidebar`), in the shape
/// of the selection an `.inset` list draws itself: a rounded rectangle 10 points in from the
/// list's edges, with a corner radius of 8, the row's full height (measured off screen on
/// macOS 27.2; `docs/mac-imessage-ui-plan.md`, "Spike results").
///
/// The fill is the only selection on screen: it carries a `MacSidebarListSelectionGuard`, which
/// stops the list drawing its own. So the shape is how the selection looks, not something that
/// has to match a shape underneath. Where the guard cannot find the list (a system that builds
/// lists another way), the list's own selection is still drawn under the fill, and the fill
/// covers it on a system whose list draws the shape above.
///
/// Selected rows that touch are one shape to the list, rounded only at its ends, so the fill is
/// square at an edge it shares with another selected row (`joins`).
///
/// `MacSidebarRowSelectionPolicy` decides the fill and the joins, and why the sidebar draws the
/// selection at all.
struct MacSidebarRowSelectionBackground: View {
    private let color: Color
    private let joins: MacSidebarRowSelectionPolicy.Joins

    private static let horizontalInset: CGFloat = 10
    private static let cornerRadius: CGFloat = 8

    /// Nil for a row that is not selected. `listRowBackground` takes an optional view, and nil
    /// leaves the row the list's own background with no view of the sidebar's behind it. Most
    /// rows of the list are not selected.
    ///
    /// The colors are the system's own selection colors, so the fill follows the accent color
    /// chosen in System Settings and the window's light or dark appearance, as a list's
    /// selection does.
    init?(fill: MacSidebarRowSelectionPolicy.Fill, joins: MacSidebarRowSelectionPolicy.Joins) {
        switch fill {
        case .none:
            return nil
        case .accent:
            color = Color(nsColor: .selectedContentBackgroundColor)
        case .inactive:
            color = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
        self.joins = joins
    }

    var body: some View {
        let top = joins.above ? 0 : Self.cornerRadius
        let bottom = joins.below ? 0 : Self.cornerRadius
        // Circular corners, the default of `RoundedRectangle` and the list's own: continuous
        // ones are a little tighter, and would let the list's selection show around them where
        // it is still drawn.
        UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: top,
            style: .circular
        )
        .fill(color)
        .padding(.horizontal, Self.horizontalInset)
        // In the fill, not on the list: the guard finds the list from inside one of its rows,
        // and a selected row is the only place the list's own selection would be drawn.
        // `MacSidebarRowSelectionBackgroundTests` mounts a real list to pin that it is found.
        .background {
            MacSidebarListSelectionGuard()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
#endif
