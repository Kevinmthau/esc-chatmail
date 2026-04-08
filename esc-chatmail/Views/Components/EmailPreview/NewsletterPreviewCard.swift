import SwiftUI
import UIKit

struct NewsletterPreviewCard: View {
    let model: NewsletterPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let heroImageURL = model.heroImageURL {
                NewsletterPreviewHeroImage(imageURL: heroImageURL)
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
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

    @State private var loadedImage: UIImage?
    @State private var isLoading = false

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
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
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
            await loadImage()
        }
    }

    private func loadImage() async {
        guard loadedImage == nil else {
            return
        }

        await MainActor.run {
            isLoading = true
        }

        let image = await EnhancedImageCache.shared.loadImage(from: imageURL)
        await MainActor.run {
            loadedImage = image
            isLoading = false
        }
    }
}
