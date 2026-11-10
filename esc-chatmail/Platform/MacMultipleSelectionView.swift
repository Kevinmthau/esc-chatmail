#if os(macOS)
import SwiftUI

/// What the Mac's chat column shows while several conversations are selected: how many, and the
/// two batch actions. A chat is not shown for any one of them, because opening a chat marks it
/// read (`MacSidebarSelectionPolicy.Detail.multiple`).
struct MacMultipleSelectionView: View {
    let count: Int
    let onArchive: @MainActor () -> Void
    let onReportSpam: @MainActor () -> Void

    var body: some View {
        ContentUnavailableView {
            SwiftUI.Label("\(count) Conversations Selected", systemImage: "bubble.left.and.bubble.right")
        } actions: {
            Button(action: onArchive) {
                SwiftUI.Label("Archive", systemImage: "archivebox")
            }
            Button(action: onReportSpam) {
                SwiftUI.Label("Report Spam", systemImage: "exclamationmark.triangle")
            }
        }
    }
}
#endif
