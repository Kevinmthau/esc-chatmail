import SwiftUI

/// The conversation list's filter menu: one choice per `ConversationFilter`, under the current
/// filter's icon. The iOS list's toolbar and the Mac sidebar's both show this one, so the two
/// cannot come to offer different filters.
struct ConversationFilterMenu: View {
    let currentFilter: ConversationFilter
    /// Called with the chosen filter. The caller applies it, and does whatever else a choice
    /// needs there (the iOS list resigns its search field's focus first).
    let onSelect: (ConversationFilter) -> Void

    var body: some View {
        Menu {
            ForEach(ConversationFilter.allCases, id: \.self) { filter in
                Button {
                    onSelect(filter)
                } label: {
                    SwiftUI.Label(filter.rawValue, systemImage: filter.icon)
                }
            }
        } label: {
            SwiftUI.Label("Filter", systemImage: currentFilter.icon)
        }
        .accessibilityLabel("Filter conversations")
    }
}
