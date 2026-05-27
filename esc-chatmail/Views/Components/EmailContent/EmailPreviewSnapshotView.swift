import SwiftUI
import UIKit

struct EmailPreviewSnapshotView: View {
    let htmlContent: String
    let previewCacheKey: String
    let isDarkMode: Bool
    let senderEmail: String?
    let message: Message?
    let fallbackToLiveWebView: Bool

    @State private var snapshotImage: UIImage?
    @State private var displayHeight: CGFloat = HTMLPreviewSizing.defaultPreviewHeight
    @State private var completedCacheKey: String?
    @State private var lastContainerWidth: CGFloat = 0
    @State private var didFail = false

    private let cache: EmailPreviewSnapshotCache
    private let renderer: EmailPreviewSnapshotRenderer

    init(
        htmlContent: String,
        previewCacheKey: String,
        isDarkMode: Bool,
        senderEmail: String?,
        message: Message?,
        fallbackToLiveWebView: Bool = true,
        cache: EmailPreviewSnapshotCache = .shared,
        renderer: EmailPreviewSnapshotRenderer = .shared
    ) {
        self.htmlContent = htmlContent
        self.previewCacheKey = previewCacheKey
        self.isDarkMode = isDarkMode
        self.senderEmail = senderEmail
        self.message = message
        self.fallbackToLiveWebView = fallbackToLiveWebView
        self.cache = cache
        self.renderer = renderer
    }

    var body: some View {
        contentView
    }

    @ViewBuilder
    private var contentView: some View {
        if didFail, fallbackToLiveWebView {
            MiniEmailWebView(
                htmlContent: htmlContent,
                previewCacheKey: previewCacheKey,
                isDarkMode: isDarkMode,
                senderEmail: senderEmail,
                message: message
            )
            .background {
                GeometryReader { geometry in
                    snapshotLoadTask(width: geometry.size.width)
                }
            }
        } else {
            GeometryReader { geometry in
                content(width: geometry.size.width)
                    .background(snapshotLoadTask(width: geometry.size.width))
            }
            .frame(height: displayHeight)
        }
    }

    private func snapshotLoadTask(width: CGFloat) -> some View {
        let effectiveWidth = width > 1 ? width : lastContainerWidth
        return Color.clear
            .task(id: loadIdentity(for: effectiveWidth)) {
                await loadSnapshot(containerWidth: effectiveWidth)
            }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if let snapshotImage {
            Image(uiImage: snapshotImage)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
                .frame(width: max(width, 1), height: displayHeight)
                .clipped()
        } else if didFail {
            unavailablePreview
        } else {
            loadingPreview
        }
    }

    private var loadingPreview: some View {
        ZStack {
            Rectangle()
                .fill(Color(uiColor: isDarkMode ? .systemGray6 : .secondarySystemBackground))
            ProgressView()
                .controlSize(.small)
        }
    }

    private var unavailablePreview: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.fill")
                .font(.callout)
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Open original email")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                Text("Preview unavailable")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func loadIdentity(for width: CGFloat) -> String {
        guard width > 1 else {
            return "pending-width"
        }

        return EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: previewCacheKey,
            renderedHTML: htmlContent,
            containerWidth: width,
            isDarkMode: isDarkMode
        )
    }

    @MainActor
    private func loadSnapshot(containerWidth: CGFloat) async {
        guard containerWidth > 1 else {
            return
        }
        lastContainerWidth = containerWidth

        let cacheKey = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: previewCacheKey,
            renderedHTML: htmlContent,
            containerWidth: containerWidth,
            isDarkMode: isDarkMode
        )

        guard completedCacheKey != cacheKey else {
            return
        }

        snapshotImage = nil
        didFail = false
        displayHeight = HTMLPreviewSizing.defaultPreviewHeight

        if let cached = await cache.load(for: cacheKey),
           let image = UIImage(data: cached.imageData) {
            guard !Task.isCancelled else {
                return
            }

            snapshotImage = image
            displayHeight = HTMLPreviewSizing.clampedHeight(cached.displayHeight)
            completedCacheKey = cacheKey
            return
        }

        do {
            let result = try await renderer.render(
                request: EmailPreviewSnapshotRequest(
                    html: htmlContent,
                    cacheKey: cacheKey,
                    containerWidth: containerWidth,
                    isDarkMode: isDarkMode,
                    senderEmail: senderEmail,
                    message: message
                )
            )

            guard !Task.isCancelled else {
                return
            }

            _ = await cache.store(
                image: result.image,
                displayHeight: result.displayHeight,
                pixelScale: result.pixelScale,
                for: result.cacheKey
            )

            guard !Task.isCancelled else {
                return
            }

            snapshotImage = result.image
            displayHeight = HTMLPreviewSizing.clampedHeight(result.displayHeight)
            completedCacheKey = cacheKey
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else {
                return
            }

            Log.debug("Email preview snapshot render failed: \(error)", category: .ui)
            didFail = true
            completedCacheKey = cacheKey
        }
    }
}
