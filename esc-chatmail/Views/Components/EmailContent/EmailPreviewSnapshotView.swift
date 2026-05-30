import SwiftUI
import UIKit

struct EmailPreviewSnapshotView: View {
    let htmlContent: String
    let previewCacheKey: String
    let isDarkMode: Bool
    let senderEmail: String?
    let message: Message?
    let messageId: String?

    @StateObject private var viewModel: EmailPreviewSnapshotViewModel

    init(
        htmlContent: String,
        previewCacheKey: String,
        isDarkMode: Bool,
        senderEmail: String?,
        message: Message?,
        messageId: String? = nil,
        cache: EmailPreviewSnapshotCache = .shared,
        renderer: (any EmailPreviewSnapshotRendering)? = nil
    ) {
        self.htmlContent = htmlContent
        self.previewCacheKey = previewCacheKey
        self.isDarkMode = isDarkMode
        self.senderEmail = senderEmail
        self.message = message
        self.messageId = messageId
        self._viewModel = StateObject(
            wrappedValue: EmailPreviewSnapshotViewModel(cache: cache, renderer: renderer)
        )
    }

    var body: some View {
        contentView
    }

    @ViewBuilder
    private var contentView: some View {
        if viewModel.didFail {
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
            .frame(height: viewModel.displayHeight)
        }
    }

    private func snapshotLoadTask(width: CGFloat) -> some View {
        let effectiveWidth = width > 1 ? width : viewModel.lastContainerWidth
        return Color.clear
            .task(id: loadIdentity(for: effectiveWidth)) {
                await viewModel.loadSnapshot(
                    htmlContent: htmlContent,
                    previewCacheKey: previewCacheKey,
                    isDarkMode: isDarkMode,
                    senderEmail: senderEmail,
                    message: message,
                    messageId: messageId,
                    containerWidth: effectiveWidth
                )
            }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if let snapshotImage = viewModel.snapshotImage {
            Image(uiImage: snapshotImage)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
                .frame(width: max(width, 1), height: viewModel.displayHeight)
                .clipped()
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
}

@MainActor
final class EmailPreviewSnapshotViewModel: ObservableObject {
    @Published private(set) var snapshotImage: UIImage?
    @Published private(set) var displayHeight: CGFloat = HTMLPreviewSizing.defaultPreviewHeight
    @Published private(set) var completedCacheKey: String?
    @Published private(set) var lastContainerWidth: CGFloat = 0
    @Published private(set) var didFail = false

    private let cache: EmailPreviewSnapshotCache
    private let renderer: (any EmailPreviewSnapshotRendering)?

    init(
        cache: EmailPreviewSnapshotCache = .shared,
        renderer: (any EmailPreviewSnapshotRendering)? = nil
    ) {
        self.cache = cache
        self.renderer = renderer
    }

    @MainActor
    func loadSnapshot(
        htmlContent: String,
        previewCacheKey: String,
        isDarkMode: Bool,
        senderEmail: String?,
        message: Message?,
        messageId: String?,
        containerWidth: CGFloat
    ) async {
        guard containerWidth > 1 else {
            return
        }
        lastContainerWidth = containerWidth
        let diagnosticMessageId = messageId ?? message?.id

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

        if let cached = await cache.load(for: cacheKey) {
            guard !Task.isCancelled else {
                return
            }

            if let image = UIImage(data: cached.imageData) {
                EmailPreviewSnapshotDiagnostics.logCacheHit(
                    cacheKey: cacheKey,
                    messageId: diagnosticMessageId
                )
                snapshotImage = image
                displayHeight = HTMLPreviewSizing.clampedHeight(cached.displayHeight)
                completedCacheKey = cacheKey
                return
            }

            EmailPreviewSnapshotDiagnostics.logCacheMiss(
                cacheKey: cacheKey,
                messageId: diagnosticMessageId,
                reason: "invalid-image-data"
            )
        } else {
            guard !Task.isCancelled else {
                return
            }

            EmailPreviewSnapshotDiagnostics.logCacheMiss(
                cacheKey: cacheKey,
                messageId: diagnosticMessageId,
                reason: "not-found"
            )
        }

        let renderStart = CFAbsoluteTimeGetCurrent()
        do {
            let renderer = renderer ?? EmailPreviewSnapshotRenderer.shared
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

            let cached = await cache.store(
                image: result.image,
                displayHeight: result.displayHeight,
                pixelScale: result.pixelScale,
                for: result.cacheKey
            )

            guard !Task.isCancelled else {
                return
            }

            EmailPreviewSnapshotDiagnostics.logRenderSuccess(
                cacheKey: result.cacheKey,
                messageId: diagnosticMessageId,
                duration: CFAbsoluteTimeGetCurrent() - renderStart,
                displayHeight: result.displayHeight,
                cacheStored: cached != nil
            )
            snapshotImage = result.image
            displayHeight = HTMLPreviewSizing.clampedHeight(result.displayHeight)
            completedCacheKey = cacheKey
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else {
                return
            }

            EmailPreviewSnapshotDiagnostics.logRenderFailure(
                cacheKey: cacheKey,
                messageId: diagnosticMessageId,
                duration: CFAbsoluteTimeGetCurrent() - renderStart,
                error: error
            )
            EmailPreviewSnapshotDiagnostics.logMiniEmailWebViewFallback(
                cacheKey: cacheKey,
                messageId: diagnosticMessageId
            )
            didFail = true
            completedCacheKey = cacheKey
        }
    }
}
