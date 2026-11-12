#if os(macOS)
import SwiftUI
import AppKit

/// The fill the Mac sidebar draws behind a selected row (`MacConversationSidebar`), in the shape
/// of the selection an `.inset` list draws itself: a rounded rectangle 10 points in from the
/// list's edges, with a corner radius of 8, the row's full height (measured off screen on
/// macOS 27.2; `docs/mac-imessage-ui-plan.md`, "Spike results"). Drawn in that shape it covers
/// the list's own selection, which is still there underneath.
///
/// Selected rows that touch are one shape to the list, rounded only at its ends, so the fill is
/// square at an edge it shares with another selected row (`joins`).
///
/// `MacSidebarRowSelectionPolicy` decides the fill and the joins, and why the sidebar draws the
/// selection at all.
struct MacSidebarRowSelectionBackground: View {
    let fill: MacSidebarRowSelectionPolicy.Fill
    let joins: MacSidebarRowSelectionPolicy.Joins

    private static let horizontalInset: CGFloat = 10
    private static let cornerRadius: CGFloat = 8

    var body: some View {
        let top = joins.above ? 0 : Self.cornerRadius
        let bottom = joins.below ? 0 : Self.cornerRadius
        // Circular corners, the default of `RoundedRectangle` and the list's own: continuous
        // ones are a little tighter and would let the list's selection show around them.
        UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: top,
            style: .circular
        )
        .fill(color)
        .padding(.horizontal, Self.horizontalInset)
    }

    /// The system's own selection colors, so the fill follows the accent color chosen in System
    /// Settings and the window's light or dark appearance, as the list's selection does.
    private var color: Color {
        switch fill {
        case .none:
            return .clear
        case .accent:
            return Color(nsColor: .selectedContentBackgroundColor)
        case .inactive:
            return Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
    }
}
#endif
