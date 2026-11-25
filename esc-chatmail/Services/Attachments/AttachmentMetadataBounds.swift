import CoreGraphics

/// The one conversion from a measured image size or PDF page count to the `Int16` attributes
/// `Attachment.width`, `height` and `pageCount` are stored in. Every writer of those three goes
/// through here.
///
/// The values are the sender's: a PNG of a few hundred bytes can declare a side of 40,000 pixels,
/// and a PDF can declare any number of pages. `Int16(_:)` traps on anything above 32,767, and the
/// Gmail download path once called it inside its processing task, before the row was written, so
/// the row stayed queued and every sweep after a sync, and every opening of that chat, killed the
/// app again (architecture review 2026-11, item 1). Nothing here can trap: the clamp is done in
/// floating point, before any conversion to an integer, so a NaN, an infinity or a value past
/// `Int.max` is handled too (`Int(_:)` traps on those as well).
///
/// Pure and nonisolated: the download path calls it inside a detached task, where no managed
/// object exists to call a setter on.
enum AttachmentMetadataBounds {
    /// One side in pixels, clamped to `0...Int16.max` and rounded. Not finite, or not positive,
    /// is 0, which every reader takes as "unknown".
    static func persistedImageDimension(_ dimension: CGFloat) -> Int16 {
        guard dimension.isFinite, dimension > 0 else { return 0 }
        let maximum = CGFloat(Int16.max)
        guard dimension < maximum else { return Int16.max }
        return Int16(dimension.rounded())
    }

    /// Both sides, scaled by one factor when the longer one is past `Int16.max`, so the reserved
    /// frame keeps the image's shape: clamped one side at a time, a 40,000 x 10,000 panorama
    /// would be stored as 32,767 x 10,000. A positive side never rounds down to 0 in that
    /// scaling. A side that is not finite or not positive is 0 and does not take part.
    static func persistedImageDimensions(_ size: CGSize) -> (width: Int16, height: Int16) {
        let width = size.width.isFinite && size.width > 0 ? size.width : 0
        let height = size.height.isFinite && size.height > 0 ? size.height : 0
        let maximum = CGFloat(Int16.max)
        let longest = max(width, height)
        guard longest > maximum else {
            return (persistedImageDimension(width), persistedImageDimension(height))
        }
        let factor = maximum / longest
        func scaled(_ side: CGFloat) -> Int16 {
            guard side > 0 else { return 0 }
            return max(1, persistedImageDimension(side * factor))
        }
        return (scaled(width), scaled(height))
    }

    /// A PDF's page count, clamped to `0...Int16.max`.
    static func persistedPDFPageCount(_ pageCount: Int) -> Int16 {
        Int16(clamping: max(0, pageCount))
    }
}
