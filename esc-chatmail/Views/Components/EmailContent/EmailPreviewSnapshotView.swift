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
            .task(id: loadTaskIdentity(for: effectiveWidth)) {
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

    private func loadTaskIdentity(for width: CGFloat) -> String {
        let identity = loadIdentity(for: width)
        guard viewModel.didFail else {
            return identity
        }
        return "\(identity)|retry:\(viewModel.retryGeneration)"
    }
}

@MainActor
final class EmailPreviewSnapshotViewModel: ObservableObject {
    @Published private(set) var snapshotImage: UIImage?
    @Published private(set) var displayHeight: CGFloat = HTMLPreviewSizing.defaultPreviewHeight
    @Published private(set) var completedCacheKey: String?
    @Published private(set) var lastContainerWidth: CGFloat = 0
    @Published private(set) var didFail = false
    @Published private(set) var retryGeneration = 0

    private let cache: EmailPreviewSnapshotCache
    private let renderer: (any EmailPreviewSnapshotRendering)?
    private let retryBackoff: TimeInterval
    private let maximumAutomaticRetryAttempts: Int
    private var loadGeneration = 0
    private var activeRequest: ActiveRequest?
    private var failedAttemptsByCacheKey: [String: FailedAttempt] = [:]
    private var retryTasksByCacheKey: [String: Task<Void, Never>] = [:]

    private struct ActiveRequest {
        let generation: Int
        let cacheKey: String
    }

    private struct FailedAttempt {
        let count: Int
        let nextRetryAt: Date
    }

    init(
        cache: EmailPreviewSnapshotCache = .shared,
        renderer: (any EmailPreviewSnapshotRendering)? = nil,
        retryBackoff: TimeInterval = 1.0,
        maximumAutomaticRetryAttempts: Int = 1
    ) {
        self.cache = cache
        self.renderer = renderer
        self.retryBackoff = retryBackoff
        self.maximumAutomaticRetryAttempts = maximumAutomaticRetryAttempts
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
        let diagnosticMessageId = messageId ?? message?.id

        let cacheKey = EmailPreviewSnapshotCacheKey.make(
            previewCacheKey: previewCacheKey,
            renderedHTML: htmlContent,
            containerWidth: containerWidth,
            isDarkMode: isDarkMode
        )

        let generation = beginRequest(cacheKey: cacheKey, containerWidth: containerWidth)

        guard completedCacheKey != cacheKey || didFail else {
            return
        }

        guard isActive(generation: generation, cacheKey: cacheKey) else {
            return
        }

        let isRetryingFailedKey = failedAttemptsByCacheKey[cacheKey] != nil
        if isRetryingFailedKey {
            didFail = true
        } else {
            snapshotImage = nil
            didFail = false
            displayHeight = HTMLPreviewSizing.defaultPreviewHeight
        }

        if let cached = await cache.load(for: cacheKey) {
            guard isActive(generation: generation, cacheKey: cacheKey) else {
                return
            }

            if let image = UIImage(data: cached.imageData) {
                EmailPreviewSnapshotDiagnostics.logCacheHit(
                    cacheKey: cacheKey,
                    messageId: diagnosticMessageId
                )
                guard isActive(generation: generation, cacheKey: cacheKey) else {
                    return
                }
                await recordSnapshotMetadata(
                    cached,
                    previewCacheKey: previewCacheKey,
                    snapshotCacheKey: cacheKey,
                    messageId: diagnosticMessageId
                )
                guard isActive(generation: generation, cacheKey: cacheKey) else {
                    return
                }
                snapshotImage = image
                displayHeight = HTMLPreviewSizing.clampedHeight(cached.displayHeight)
                completedCacheKey = cacheKey
                clearFailedAttempt(for: cacheKey)
                return
            }

            EmailPreviewSnapshotDiagnostics.logCacheMiss(
                cacheKey: cacheKey,
                messageId: diagnosticMessageId,
                reason: "invalid-image-data"
            )
        } else {
            guard isActive(generation: generation, cacheKey: cacheKey) else {
                return
            }

            EmailPreviewSnapshotDiagnostics.logCacheMiss(
                cacheKey: cacheKey,
                messageId: diagnosticMessageId,
                reason: "not-found"
            )
        }

        guard shouldAttemptRender(cacheKey: cacheKey) else {
            return
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

            guard result.cacheKey == cacheKey,
                  isActive(generation: generation, cacheKey: cacheKey) else {
                return
            }

            let cached = await cache.store(
                image: result.image,
                displayHeight: result.displayHeight,
                pixelScale: result.pixelScale,
                for: result.cacheKey
            )

            guard isActive(generation: generation, cacheKey: cacheKey) else {
                return
            }

            EmailPreviewSnapshotDiagnostics.logRenderSuccess(
                cacheKey: result.cacheKey,
                messageId: diagnosticMessageId,
                duration: CFAbsoluteTimeGetCurrent() - renderStart,
                displayHeight: result.displayHeight,
                cacheStored: cached != nil
            )
            if let cached {
                guard isActive(generation: generation, cacheKey: cacheKey) else {
                    return
                }
                await recordSnapshotMetadata(
                    cached,
                    previewCacheKey: previewCacheKey,
                    snapshotCacheKey: result.cacheKey,
                    messageId: diagnosticMessageId
                )
                guard isActive(generation: generation, cacheKey: cacheKey) else {
                    return
                }
            }
            snapshotImage = result.image
            displayHeight = HTMLPreviewSizing.clampedHeight(result.displayHeight)
            completedCacheKey = cacheKey
            clearFailedAttempt(for: cacheKey)
        } catch is CancellationError {
            return
        } catch {
            guard isActive(generation: generation, cacheKey: cacheKey) else {
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
            recordFailedAttempt(for: cacheKey)
        }
    }

    private func beginRequest(cacheKey: String, containerWidth: CGFloat) -> Int {
        loadGeneration &+= 1
        let generation = loadGeneration
        activeRequest = ActiveRequest(generation: generation, cacheKey: cacheKey)
        lastContainerWidth = containerWidth
        return generation
    }

    private func isActive(generation: Int, cacheKey: String) -> Bool {
        guard !Task.isCancelled,
              activeRequest?.generation == generation,
              activeRequest?.cacheKey == cacheKey else {
            return false
        }
        return true
    }

    private func shouldAttemptRender(cacheKey: String) -> Bool {
        guard let failedAttempt = failedAttemptsByCacheKey[cacheKey] else {
            return true
        }
        return Date() >= failedAttempt.nextRetryAt
    }

    private func recordFailedAttempt(for cacheKey: String) {
        let previousCount = failedAttemptsByCacheKey[cacheKey]?.count ?? 0
        let count = previousCount + 1
        let delay = retryDelay(failureCount: count)
        failedAttemptsByCacheKey[cacheKey] = FailedAttempt(
            count: count,
            nextRetryAt: Date().addingTimeInterval(delay)
        )

        guard count <= maximumAutomaticRetryAttempts else {
            cancelRetry(for: cacheKey)
            return
        }

        scheduleRetry(cacheKey: cacheKey, failureCount: count, delay: delay)
    }

    private func clearFailedAttempt(for cacheKey: String) {
        failedAttemptsByCacheKey[cacheKey] = nil
        didFail = false
        cancelRetry(for: cacheKey)
    }

    private func retryDelay(failureCount: Int) -> TimeInterval {
        let multiplier = pow(2.0, Double(max(0, failureCount - 1)))
        return min(30.0, max(0.05, retryBackoff * multiplier))
    }

    private func scheduleRetry(cacheKey: String, failureCount: Int, delay: TimeInterval) {
        cancelRetry(for: cacheKey)
        retryTasksByCacheKey[cacheKey] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            await self?.triggerRetry(cacheKey: cacheKey, failureCount: failureCount)
        }
    }

    private func triggerRetry(cacheKey: String, failureCount: Int) {
        retryTasksByCacheKey[cacheKey] = nil
        guard didFail,
              activeRequest?.cacheKey == cacheKey,
              failedAttemptsByCacheKey[cacheKey]?.count == failureCount else {
            return
        }
        retryGeneration &+= 1
    }

    private func cancelRetry(for cacheKey: String) {
        retryTasksByCacheKey[cacheKey]?.cancel()
        retryTasksByCacheKey[cacheKey] = nil
    }

    private func recordSnapshotMetadata(
        _ entry: EmailPreviewSnapshotCacheEntry,
        previewCacheKey: String,
        snapshotCacheKey: String,
        messageId: String?
    ) async {
        guard let messageId,
              let sourceSignature = Self.sourceSignature(
                fromPreviewCacheKey: previewCacheKey,
                messageId: messageId
              ) else {
            return
        }

        await RenderedMessageCache.shared.recordSnapshotMetadata(
            RenderedMessageSnapshotMetadata(
                snapshotCacheKey: snapshotCacheKey,
                displayHeight: Double(entry.displayHeight),
                pixelScale: Double(entry.pixelScale),
                createdAt: entry.createdAt
            ),
            messageId: messageId,
            sourceSignature: sourceSignature,
            variantKey: RenderedMessageVariantKey("snapshot:\(snapshotCacheKey)")
        )
    }

    private static func sourceSignature(
        fromPreviewCacheKey previewCacheKey: String,
        messageId: String
    ) -> String? {
        let prefix = "\(messageId)|"
        guard previewCacheKey.hasPrefix(prefix) else {
            return nil
        }

        let remainder = previewCacheKey.dropFirst(prefix.count)
        guard let modeRange = remainder.range(of: "|mode:") else {
            return nil
        }

        let sourceSignature = remainder[..<modeRange.lowerBound]
        return sourceSignature.isEmpty ? nil : String(sourceSignature)
    }
}
