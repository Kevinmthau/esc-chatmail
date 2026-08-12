import UIKit

/// Reusable thumbnail loader for attachment views
/// Eliminates duplicate loading logic across ImageAttachmentBubble, AttachmentGridItem, PDFAttachmentCard, etc.
@MainActor
final class AttachmentThumbnailLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false

    private let cache = AttachmentCacheActor.shared
    private var loadTask: Task<Void, Never>?
    private var currentRequest: LoadRequest?
    /// Seam for tests: production routes to AttachmentCacheActor's budgeted,
    /// deduplicated video-frame extraction.
    private let loadVideoThumbnailOperation: @Sendable (
        _ attachmentId: String,
        _ messageId: String?,
        _ localPath: String?,
        _ targetSize: CGSize
    ) async -> UIImage?

    private enum LoadRequest: Equatable {
        case thumbnail(
            attachmentId: String,
            messageId: String?,
            previewPath: String?
        )
        case downsampled(
            attachmentId: String,
            messageId: String?,
            localPath: String?,
            previewPath: String?,
            targetSize: CGSize,
            isImage: Bool
        )
        case videoThumbnail(
            attachmentId: String,
            messageId: String?,
            localPath: String?,
            targetSize: CGSize
        )
    }

    init(
        loadVideoThumbnailOperation: (@Sendable (
            String, String?, String?, CGSize
        ) async -> UIImage?)? = nil
    ) {
        self.loadVideoThumbnailOperation = loadVideoThumbnailOperation
            ?? { attachmentId, messageId, localPath, targetSize in
                await AttachmentCacheActor.shared.loadVideoThumbnail(
                    for: attachmentId,
                    messageId: messageId,
                    from: localPath,
                    targetSize: targetSize
                )
            }
    }

    deinit {
        loadTask?.cancel()
    }

    /// Load thumbnail from preview path
    func load(attachmentId: String?, messageId: String? = nil, previewPath: String?) {
        guard let attachmentId else {
            reset()
            return
        }
        let request = LoadRequest.thumbnail(
            attachmentId: attachmentId,
            messageId: messageId,
            previewPath: previewPath
        )
        prepare(for: request)
        guard AttachmentPaths.isReadableStoragePath(
            previewPath,
            messageId: messageId,
            attachmentId: attachmentId
        ), image == nil, !isLoading else {
            return
        }

        // Cancel any existing task to prevent orphaned tasks
        loadTask?.cancel()

        isLoading = true
        loadTask = Task {
            let loadedImage = await cache.loadThumbnail(
                for: attachmentId,
                messageId: messageId,
                from: previewPath
            )
            guard !Task.isCancelled else { return }
            self.image = loadedImage
            self.isLoading = false
        }
    }

    /// Load with downsampling for grid views (tries downsampled first, falls back to preview)
    func loadDownsampled(
        attachmentId: String?,
        messageId: String? = nil,
        localPath: String?,
        previewPath: String?,
        targetSize: CGSize,
        isImage: Bool
    ) {
        guard let attachmentId else {
            reset()
            return
        }
        let request = LoadRequest.downsampled(
            attachmentId: attachmentId,
            messageId: messageId,
            localPath: localPath,
            previewPath: previewPath,
            targetSize: targetSize,
            isImage: isImage
        )
        prepare(for: request)

        let readableLocalPath = localPath.flatMap { path in
            AttachmentPaths.isReadableStoragePath(
                path,
                messageId: messageId,
                attachmentId: attachmentId
            ) ? path : nil
        }
        let readablePreviewPath = previewPath.flatMap { path in
            AttachmentPaths.isReadableStoragePath(
                path,
                messageId: messageId,
                attachmentId: attachmentId
            ) ? path : nil
        }
        guard (isImage && readableLocalPath != nil) || readablePreviewPath != nil,
              image == nil,
              !isLoading else {
            return
        }

        // Cancel any existing task to prevent orphaned tasks
        loadTask?.cancel()

        isLoading = true
        loadTask = Task {
            var loadedImage: UIImage?

            // Try downsampled first for images with local path
            if let readableLocalPath, isImage {
                loadedImage = await cache.loadDownsampledImage(
                    for: attachmentId,
                    messageId: messageId,
                    from: readableLocalPath,
                    targetSize: targetSize
                )
            }

            // Fall back to preview thumbnail
            if loadedImage == nil {
                loadedImage = await cache.loadThumbnail(
                    for: attachmentId,
                    messageId: messageId,
                    from: readablePreviewPath
                )
            }

            guard !Task.isCancelled else { return }
            self.image = loadedImage
            self.isLoading = false
        }
    }

    /// Load a poster frame for a video attachment from its local file.
    func loadVideoThumbnail(
        attachmentId: String?,
        messageId: String? = nil,
        localPath: String?,
        targetSize: CGSize
    ) {
        guard let attachmentId else {
            reset()
            return
        }
        let request = LoadRequest.videoThumbnail(
            attachmentId: attachmentId,
            messageId: messageId,
            localPath: localPath,
            targetSize: targetSize
        )
        prepare(for: request)
        guard AttachmentPaths.isReadableStoragePath(
            localPath,
            messageId: messageId,
            attachmentId: attachmentId
        ), image == nil, !isLoading else {
            return
        }

        // Cancel any existing task to prevent orphaned tasks
        loadTask?.cancel()

        isLoading = true
        let operation = loadVideoThumbnailOperation
        loadTask = Task {
            let loadedImage = await operation(attachmentId, messageId, localPath, targetSize)
            guard !Task.isCancelled else { return }
            self.image = loadedImage
            self.isLoading = false
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    func reset() {
        cancel()
        image = nil
        currentRequest = nil
    }

    private func prepare(for request: LoadRequest) {
        guard currentRequest != request else { return }
        loadTask?.cancel()
        loadTask = nil
        image = nil
        isLoading = false
        currentRequest = request
    }
}
