import UIKit

/// Shared load path for remote images shown on native preview cards.
/// Every card image fetch goes through the auto-load gate here so the
/// remote-image policy cannot drift between card views.
enum EmailPreviewCardImageLoader {
    static func loadImage(from rawURL: String) async -> UIImage? {
        guard let autoLoadableURL = EmailPreviewRemoteImageURL.autoLoadableNativePreviewURL(rawURL) else {
            return nil
        }

        return await EnhancedImageCache.shared.loadImage(from: autoLoadableURL)
    }
}
