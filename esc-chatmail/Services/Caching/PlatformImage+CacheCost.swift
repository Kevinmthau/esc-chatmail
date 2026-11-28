import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension PlatformImage {
    /// Estimated decoded bitmap footprint in bytes, for cache cost accounting: what the bitmap's
    /// rows hold (`bytesPerRow` × height) where the image has one, so a 16-bit-per-channel image
    /// is charged its 8 bytes a pixel, not 4; otherwise its pixel dimensions (points × scale) at
    /// 4 bytes per pixel. Every image cache charges through this, so eviction pressure is
    /// comparable across them.
    var estimatedCacheCost: Int {
        if let bitmap = cgImage {
            return bitmap.bytesPerRow * bitmap.height
        }
        return Int(size.width * size.height * 4 * scale * scale)
    }
}
