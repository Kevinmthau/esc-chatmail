import UIKit

/// Reusable thumbnail loader for attachment views
/// Eliminates duplicate loading logic across ImageAttachmentBubble, AttachmentGridItem, PDFAttachmentCard, etc.
@MainActor
final class AttachmentThumbnailLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false

    private let cache = AttachmentCacheActor.shared
    private var loadTask: Task<Void, Never>?

    /// Load thumbnail from preview path
    func load(attachmentId: String?, previewPath: String?) {
        guard let attachmentId, image == nil, !isLoading else { return }

        // Cancel any existing task to prevent orphaned tasks
        loadTask?.cancel()

        isLoading = true
        loadTask = Task {
            let loadedImage = await cache.loadThumbnail(for: attachmentId, from: previewPath)
            guard !Task.isCancelled else { return }
            self.image = loadedImage
            self.isLoading = false
        }
    }

    /// Load with downsampling for grid views (tries downsampled first, falls back to preview)
    func loadDownsampled(
        attachmentId: String?,
        localPath: String?,
        previewPath: String?,
        targetSize: CGSize,
        isImage: Bool
    ) {
        guard let attachmentId, image == nil, !isLoading else { return }

        // Cancel any existing task to prevent orphaned tasks
        loadTask?.cancel()

        isLoading = true
        loadTask = Task {
            var loadedImage: UIImage?

            // Try downsampled first for images with local path
            if let localPath, isImage {
                loadedImage = await cache.loadDownsampledImage(
                    for: attachmentId,
                    from: localPath,
                    targetSize: targetSize
                )
            }

            // Fall back to preview thumbnail
            if loadedImage == nil {
                loadedImage = await cache.loadThumbnail(for: attachmentId, from: previewPath)
            }

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
    }
}
