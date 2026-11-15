import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TransactionalPreviewCard: View {
    let model: TransactionalPreviewModel
    @Environment(\.emailPreviewCardMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            HStack(alignment: .center, spacing: 12) {
                if let imageURL = model.imageURL {
                    TransactionalPreviewThumbnail(
                        imageURL: imageURL,
                        style: model.imageStyle
                    )
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(model.title)
                        .font(metrics.font(\.titleSize, .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let subtitle = model.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(metrics.font(\.subtitleSize, .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let detailLine = model.detailLine, !detailLine.isEmpty {
                        Text(detailLine)
                            .font(metrics.font(\.secondaryDetailSize, .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }

                    if let actionLabel = model.actionLabel, !actionLabel.isEmpty {
                        Text(actionLabel)
                            .font(metrics.font(\.labelSize, .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let amount = model.amount, !amount.isEmpty {
                    Text(amount)
                        .font(metrics.font(\.amountSize, .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(metrics.cardPadding)
        .frame(maxWidth: .infinity, minHeight: metrics.transactionalCardMinHeight, alignment: .leading)
        .emailPreviewCardChrome()
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if let sourceLine {
                Text(sourceLine)
                    .font(metrics.font(\.labelSize, .semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }

            if let sourceDomain = model.sourceDomain,
               sourceDomain != sourceLine {
                Text(sourceDomain)
                    .font(metrics.font(\.labelSize, .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let status = model.status, !status.isEmpty {
                Text(status)
                    .font(metrics.font(\.labelSize, .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.tertiarySystemFill)
                    )
                    .lineLimit(1)
            }
        }
    }

    private var sourceLine: String? {
        if let sourceLabel = model.sourceLabel, !sourceLabel.isEmpty {
            return sourceLabel
        }

        if let sourceDomain = model.sourceDomain, !sourceDomain.isEmpty {
            return sourceDomain
        }

        return nil
    }
}

private struct TransactionalPreviewThumbnail: View {
    let imageURL: String
    let style: TransactionalPreviewImageStyle

    @State private var loadedImage: PlatformImage?
    @State private var isLoading = false
    @State private var activeImageURL: String?

    private let avatarSize: CGFloat = 52
    private let cardSize = CGSize(width: 56, height: 56)

    var body: some View {
        Group {
            if let loadedImage {
                thumbnailImage(for: loadedImage)
            } else {
                placeholder
            }
        }
        .task(id: imageURL) {
            await loadImage(for: imageURL)
        }
    }

    @ViewBuilder
    private func thumbnailImage(for image: PlatformImage) -> some View {
        switch style {
        case .avatar:
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())
        case .card:
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: cardSize.width, height: cardSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch style {
        case .avatar:
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.accentColor.opacity(0.65))
                }
            }
            .frame(width: avatarSize, height: avatarSize)
        case .card:
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.accentColor.opacity(0.65))
                }
            }
            .frame(width: cardSize.width, height: cardSize.height)
        }
    }

    private func loadImage(for requestedURL: String) async {
        await MainActor.run {
            activeImageURL = requestedURL
            loadedImage = nil
            isLoading = true
        }

        let image = await EmailPreviewCardImageLoader.loadImage(from: requestedURL)
        guard !Task.isCancelled else {
            return
        }

        await MainActor.run {
            guard activeImageURL == requestedURL else {
                return
            }
            loadedImage = image
            isLoading = false
        }
    }
}
