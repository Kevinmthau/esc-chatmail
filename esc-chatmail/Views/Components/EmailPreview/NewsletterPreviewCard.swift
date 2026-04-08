import SwiftUI
import UIKit

struct NewsletterPreviewCard: View {
    let model: NewsletterPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let heroImageURL = model.heroImageURL {
                NewsletterPreviewHeroImage(
                    imageURL: heroImageURL,
                    displayMode: model.heroImageDisplayMode
                )
                    .frame(height: 142)
                    .clipped()
            }

            VStack(alignment: .leading, spacing: 10) {
                header

                Text(model.title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(model.heroImageURL == nil ? 3 : 2)

                if let subtitle = model.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(model.snippet)
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(model.heroImageURL == nil ? 4 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .emailPreviewCardChrome()
    }

    @ViewBuilder
    private var header: some View {
        if let sourceLine = sourceLine {
            HStack(spacing: 8) {
                Text(sourceLine)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)

                if let sourceDomain = model.sourceDomain, sourceDomain != sourceLine {
                    Text(sourceDomain)
                        .font(.system(size: 11, weight: .medium, design: .default))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
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

private struct NewsletterPreviewHeroImage: View {
    let imageURL: String
    let displayMode: NewsletterPreviewHeroImageDisplayMode

    @State private var loadedImage: UIImage?
    @State private var isLoading = false
    @State private var activeImageURL: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.18),
                    Color.primary.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let loadedImage {
                heroImageView(for: loadedImage)
                    .transition(.opacity)
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
            } else {
                Image(systemName: "newspaper.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: imageURL) {
            await loadImage(for: imageURL)
        }
    }

    @ViewBuilder
    private func heroImageView(for image: UIImage) -> some View {
        switch displayMode {
        case .fill:
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        case .fit:
            VStack(spacing: 0) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)

                Spacer(minLength: 0)
            }
        }
    }

    private func loadImage(for requestedURL: String) async {
        await MainActor.run {
            activeImageURL = requestedURL
            loadedImage = nil
            isLoading = true
        }

        let image = await EnhancedImageCache.shared.loadImage(from: requestedURL)
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
