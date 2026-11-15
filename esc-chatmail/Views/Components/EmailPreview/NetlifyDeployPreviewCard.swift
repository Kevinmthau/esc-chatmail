import SwiftUI

struct NetlifyDeployPreviewCard: View {
    let model: NetlifyDeployPreviewModel
    @Environment(\.emailPreviewCardMetrics) private var metrics

    private var accentColor: Color {
        Color(red: 0.0, green: 0.68, blue: 0.67)
    }

    private var statusColor: Color {
        switch model.status {
        case .processing: return .orange
        case .ready: return .green
        case .failed: return .red
        }
    }

    private var iconSystemName: String {
        switch model.status {
        case .processing: return "hammer.fill"
        case .ready: return "checkmark.seal.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(alignment: .top, spacing: 12) {
                iconTile

                VStack(alignment: .leading, spacing: 5) {
                    Text(model.title)
                        .font(metrics.font(\.titleSize, .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let repoSlug = model.repoSlug, !repoSlug.isEmpty {
                        Text(repoSlug)
                            .font(metrics.font(\.secondaryDetailSize, .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let commitSHA = model.commitSHA, !commitSHA.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "number")
                                .font(metrics.font(\.labelSize, .semibold))
                                .foregroundStyle(.tertiary)
                            Text(commitSHA)
                                .font(.system(size: metrics.secondaryDetailSize, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if model.deployLogURL != nil {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right.square")
                                .font(metrics.font(\.labelSize, .semibold))
                            Text("View deploy log")
                                .font(metrics.font(\.secondaryDetailSize, .semibold))
                        }
                        .foregroundStyle(accentColor)
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(metrics.cardPadding)
        .frame(maxWidth: .infinity, minHeight: metrics.deployCardMinHeight, alignment: .leading)
        .emailPreviewCardChrome()
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(model.sourceLabel)
                .font(metrics.font(\.labelSize, .semibold))
                .foregroundStyle(accentColor)
                .lineLimit(1)

            Spacer(minLength: 0)

            statusCapsule
        }
    }

    private var statusCapsule: some View {
        HStack(spacing: 6) {
            if model.status == .processing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(statusColor)
            }

            Text(model.status.displayText)
                .font(metrics.font(\.labelSize, .semibold))
                .foregroundStyle(statusColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(statusColor.opacity(0.15))
        )
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accentColor.opacity(0.15))

            Image(systemName: iconSystemName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accentColor)
        }
        .frame(width: 44, height: 44)
    }
}
