import SwiftUI

struct NetlifyDeployPreviewCard: View {
    let model: NetlifyDeployPreviewModel

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
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let repoSlug = model.repoSlug, !repoSlug.isEmpty {
                        Text(repoSlug)
                            .font(.system(size: 12, weight: .medium, design: .default))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let commitSHA = model.commitSHA, !commitSHA.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "number")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(commitSHA)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if model.deployLogURL != nil {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11, weight: .semibold))
                            Text("View deploy log")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(accentColor)
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .emailPreviewCardChrome()
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(model.sourceLabel)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
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
                .font(.system(size: 11, weight: .semibold, design: .rounded))
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
