import UIKit

extension UIImage {
    /// Estimated decoded bitmap footprint in bytes, for NSCache cost
    /// accounting: pixel dimensions (points × scale) at 4 bytes per pixel.
    /// Same formula as AttachmentCacheActor's full-image cost, so eviction
    /// pressure is comparable across the image caches.
    var estimatedCacheCost: Int {
        Int(size.width * size.height * 4 * scale * scale)
    }
}
