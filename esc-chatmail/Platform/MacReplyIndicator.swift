#if os(macOS)
import SwiftUI

/// The row above the Mac's reply field that says what the reply answers
/// (`ReplyIndicatorPolicy.Header`), drawn as a small capsule to go with the field under it.
///
/// It says and offers what the iPhone's row does: the quoted message with an X that drops the
/// quote, a recovered reply's recipients with no button, or an unavailable target with
/// "Clear target". Nothing is drawn for `.none`.
struct MacReplyIndicator: View {
    let header: ReplyIndicatorPolicy.Header
    let metrics: ChatComposerMetrics
    /// Whether the row's buttons take a click (`ChatReplyBarControlPolicy.allowsDraftMutation`).
    let allowsDraftMutation: Bool
    let onDropQuote: () -> Void
    let onClearUnavailableTarget: () -> Void

    var body: some View {
        switch header {
        case .none:
            EmptyView()
        case .replyingTo(let label):
            capsule {
                Image(systemName: "arrow.turn.up.left")
                    .accessibilityHidden(true)
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button(action: onDropQuote) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(!allowsDraftMutation)
                .help("Don’t quote this message")
                .accessibilityLabel("Don’t quote this message")
            }
        case .recoveredEnvelope(let label):
            capsule {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .unavailableTarget:
            capsule {
                Text("Original reply target unavailable")
                    .lineLimit(1)
                Button("Clear target", action: onClearUnavailableTarget)
                    .buttonStyle(.link)
                    .disabled(!allowsDraftMutation)
            }
        }
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) {
            content()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        // A fixed height, whatever the row holds: the row is part of the composer's height,
        // and so of the transcript's bottom inset.
        .frame(height: metrics.replyIndicatorHeight)
        .background(Capsule().fill(Color.systemBackground))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }
}
#endif
