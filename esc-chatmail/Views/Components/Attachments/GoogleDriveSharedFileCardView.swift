import SwiftUI
import UIKit

struct GoogleDriveSharedFileCardView: View {
    let link: SharedDocumentLink

    @Environment(\.openURL) private var openURL
    @State private var metadata: GoogleDriveSharedFileMetadata?
    @State private var isLoadingMetadata = false

    var body: some View {
        Button {
            openURL(link.url)
        } label: {
            GoogleDriveSharedFileCardContent(
                link: link,
                metadata: metadata,
                isLoadingMetadata: isLoadingMetadata
            )
        }
        .buttonStyle(.plain)
        .task(id: link.id) {
            await loadMetadata()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the shared Google file")
    }

    private var accessibilityLabel: String {
        let resolvedTitle = metadata?.title ?? link.kind.title
        return "\(resolvedTitle), \(link.sourceLabel)"
    }

    private func loadMetadata() async {
        if metadata != nil || isLoadingMetadata {
            return
        }

        await MainActor.run {
            isLoadingMetadata = true
        }

        let resolvedMetadata = await GoogleDriveSharedFileMetadataProvider.shared.metadata(for: link)
        guard !Task.isCancelled else {
            return
        }

        await MainActor.run {
            metadata = resolvedMetadata
            isLoadingMetadata = false
        }
    }
}

/// The card's layout for one metadata state. It owns no state and starts no metadata load
/// (`GoogleDriveSharedFileCardView` does both), so a test can mount each state directly.
///
/// Its height must not depend on `metadata` or `isLoadingMetadata`. The row is on screen
/// before the card's metadata task has run (a title the provider already caches still arrives
/// a pass after mount), so a height that follows the title resizes a mounted row and shifts
/// the chat transcript; `MessageDisplayPolicy.showsTextLoadingPlaceholder` describes what a
/// row resizing after mount costs the chat's hidden initial-anchor pass.
struct GoogleDriveSharedFileCardContent: View {
    let link: SharedDocumentLink
    let metadata: GoogleDriveSharedFileMetadata?
    let isLoadingMetadata: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GoogleDriveSharedFilePreview(
                link: link,
                thumbnailURL: metadata?.thumbnailURL,
                isLoadingMetadata: isLoadingMetadata
            )
            .frame(height: 154)

            VStack(alignment: .leading, spacing: 6) {
                titleBlock

                Text(link.sourceLabel)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 0.6)
        )
    }

    private var resolvedTitle: String? {
        guard let title = metadata?.title, !title.isEmpty else {
            return nil
        }
        return title
    }

    /// Two title lines tall in every state: the title reserves both lines whatever its length
    /// (`reservesSpace`), and the skeleton is drawn over that same reserved text rather than
    /// sized on its own, so the two cannot drift apart with the font.
    ///
    /// They used to be sized separately. The skeleton was 44pt (two 18pt bars, 8pt apart), a
    /// one-line title 21.67pt and a two-line title 43pt, so the card shrank by 22.33pt when
    /// metadata resolved to a one-line title (the usual case, and always for the
    /// `link.kind.title` fallback) and by 1pt for a longer one.
    ///
    /// The title font is a fixed 18pt and does not follow Dynamic Type; the reserved height
    /// comes from the text itself, so it would hold if that changed.
    private var titleBlock: some View {
        // The blank stand-in draws nothing; it only reserves the two lines.
        Text(resolvedTitle ?? " ")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(2, reservesSpace: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                if resolvedTitle == nil {
                    titleSkeleton
                }
            }
    }

    /// One bar per reserved title line, pinned to the top and bottom of the reserved area.
    private var titleSkeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            skeletonLine(width: 196, height: 18)
            Spacer(minLength: 0)
            skeletonLine(width: 142, height: 18)
        }
        .accessibilityHidden(true)
    }

    private var cardBackground: Color {
        Color(uiColor: .systemGray6)
    }

    private var cardBorder: Color {
        Color(uiColor: .separator).opacity(0.18)
    }

    @ViewBuilder
    private func skeletonLine(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(uiColor: .tertiarySystemFill))
            .frame(width: width, height: height)
    }
}

private struct GoogleDriveSharedFilePreview: View {
    let link: SharedDocumentLink
    let thumbnailURL: String?
    let isLoadingMetadata: Bool

    @State private var loadedImage: UIImage?
    @State private var isLoadingImage = false
    @State private var activeThumbnailURL: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    accentColor.opacity(0.22),
                    Color(uiColor: .tertiarySystemFill)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if isLoadingMetadata || isLoadingImage {
                previewSkeleton
            } else {
                fallbackPreview
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: thumbnailURL) {
            await loadImage(for: thumbnailURL)
        }
    }

    private var accentColor: Color {
        switch link.kind {
        case .googleDoc:
            return .blue
        case .googleSheet:
            return .green
        case .googleSlides:
            return .orange
        case .googleDriveFile:
            return .indigo
        case .googleDriveFolder:
            return .teal
        }
    }

    private var fallbackSymbolName: String {
        switch link.kind {
        case .googleDoc:
            return "doc.text.fill"
        case .googleSheet:
            return "tablecells.fill"
        case .googleSlides:
            return "rectangle.on.rectangle.fill"
        case .googleDriveFile:
            return "doc.fill"
        case .googleDriveFolder:
            return "folder.fill"
        }
    }

    private var fallbackKindLabel: String {
        switch link.kind {
        case .googleDoc:
            return "DOC"
        case .googleSheet:
            return "SHEET"
        case .googleSlides:
            return "SLIDES"
        case .googleDriveFile:
            return "FILE"
        case .googleDriveFolder:
            return "FOLDER"
        }
    }

    private var previewSkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.42))
                .frame(width: 120, height: 12)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.32))
                .frame(width: 176, height: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(16)
    }

    private var fallbackPreview: some View {
        VStack(spacing: 10) {
            Image(systemName: fallbackSymbolName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(accentColor.opacity(0.9))

            Text(fallbackKindLabel)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(1.1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadImage(for requestedURL: String?) async {
        guard let requestedURL, !requestedURL.isEmpty else {
            await MainActor.run {
                activeThumbnailURL = nil
                loadedImage = nil
                isLoadingImage = false
            }
            return
        }

        await MainActor.run {
            activeThumbnailURL = requestedURL
            loadedImage = nil
            isLoadingImage = true
        }

        let image = await EnhancedImageCache.shared.loadImage(from: requestedURL)
        guard !Task.isCancelled else {
            return
        }

        await MainActor.run {
            guard activeThumbnailURL == requestedURL else {
                return
            }

            loadedImage = image.flatMap { loadedImage in
                guard loadedImage.size.width > 1, loadedImage.size.height > 1 else {
                    return nil
                }
                return loadedImage
            }
            isLoadingImage = false
        }
    }
}
