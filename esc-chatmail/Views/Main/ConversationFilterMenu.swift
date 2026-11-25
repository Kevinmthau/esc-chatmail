import SwiftUI

/// The conversation list's filter menu: one choice per `ConversationFilter`, under the current
/// filter's icon. The iOS list's toolbar and the Mac sidebar's both show this one, so the two
/// cannot come to offer different filters.
struct ConversationFilterMenu: View {
    let currentFilter: ConversationFilter
    /// Adds Share Diagnostics… below the filters (`DiagnosticsReportFile`). The iOS list
    /// asks for it, because iOS has no other screen of the app's own to put it on; the Mac
    /// sidebar does not, and keeps no MetricKit records.
    var showsDiagnosticsShare = false
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
            if showsDiagnosticsShare {
                Divider()
                ShareLink(
                    item: DiagnosticsReportFile(),
                    preview: SharePreview("MushMail Diagnostics")
                ) {
                    SwiftUI.Label("Share Diagnostics…", systemImage: "stethoscope")
                }
            }
        } label: {
            SwiftUI.Label("Filter", systemImage: currentFilter.icon)
        }
        .accessibilityLabel("Filter conversations")
    }
}
