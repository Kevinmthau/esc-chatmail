import SwiftUI

/// "Not enough storage", with a Retry: what an attachment shows when its download was refused,
/// or stopped, for want of space (`AttachmentDownloadIndicatorPolicy.Indicator.refusedForSpace`).
struct AttachmentSpaceRefusalButton: View {
    let onRetry: () -> Void

    var body: some View {
        Button(action: onRetry) {
            SwiftUI.Label("Not enough storage", systemImage: "arrow.clockwise.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.orange)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Tries the download again")
    }
}
