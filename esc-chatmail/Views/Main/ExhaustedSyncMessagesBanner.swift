import SwiftUI

/// The conversation list's first rows while sync has given up on messages it
/// could not download (`ExhaustedSyncMessagesPolicy`). Retry gives them back to
/// the drain and syncs; Open in Gmail shows the first in Gmail on the web.
struct ExhaustedSyncMessagesBanner: View {
    let summary: ExhaustedSyncMessagesPolicy.Summary
    let gmailURL: URL?
    let onRetry: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "envelope.badge.exclamationmark")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(.subheadline.weight(.semibold))
                Text(summary.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Retry", action: onRetry)
                    if let gmailURL {
                        Button("Open in Gmail") {
                            openURL(gmailURL)
                        }
                        .tint(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
