import SwiftUI

/// The conversation list's first row while pending actions sit abandoned.
/// Retry resets them to pending and runs the queue; Dismiss deletes them.
struct AbandonedPendingActionsBanner: View {
    let summary: AbandonedPendingActionsPolicy.Summary
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
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
                    Button("Dismiss", action: onDismiss)
                        .tint(.secondary)
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
