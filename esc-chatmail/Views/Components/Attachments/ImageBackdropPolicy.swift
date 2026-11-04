import SwiftUI

/// What a decoded attachment image needs behind it to be seen at all.
///
/// An attachment image draws straight onto the transcript, so a transparent image's only
/// backdrop is whatever the appearance happens to be. A black logo on a transparent canvas, the
/// usual letterhead or signature asset, drew black on dark mode's black: a bubble-sized empty box
/// with its image loaded and nothing to show for it. A white logo did the same in light mode.
///
/// Decided from the pixels and never from the color scheme: the card follows the image, so it
/// does not change when the appearance does. The single-attachment bubble reads `ImageProcessor`'s
/// thumbnail, which keeps an image within its size limit byte for byte, transparency included,
/// and flattens a larger one onto white. The grid reads the original, at any size.
enum ImageBackdropPolicy: Equatable {
    /// Reads as an opaque picture, or holds mid-tone content that shows on either background;
    /// whatever is already behind it stays. A round headshot or a colorful logo floated fine on
    /// the transcript and must not gain a square around it.
    case none
    /// Mostly dark content on transparency, which needs a light card.
    case light
    /// Mostly light content on transparency, which needs a dark card.
    case dark
    /// No pixel holds anything to see, so no card could help: this is the thumbnail placeholder's
    /// job, in the geometry the attachment's metadata already reserved.
    case nothingVisible

    /// The card to draw behind the image; nil when the backdrop leaves the background alone.
    var matteColor: Color? {
        switch self {
        case .light:
            return .white
        case .dark:
            // The email reader's dark canvas (`HTMLDisplayWrapper.Theme`).
            return Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
        case .none, .nothingVisible:
            return nil
        }
    }

    /// Off the main actor once there is a bitmap to read: a thumbnail decodes lazily, on its
    /// first draw. An image whose format has no alpha channel answers without one.
    static func resolve(for image: UIImage?) async -> Self {
        guard let cgImage = image?.cgImage, mayHaveTransparency(cgImage) else { return .none }
        return await Task.detached(priority: .userInitiated) {
            resolve(for: cgImage)
        }.value
    }

    static func resolve(for cgImage: CGImage) -> Self {
        guard mayHaveTransparency(cgImage) else { return .none }

        var pixels = [UInt8](repeating: 0, count: sampleSide * sampleSide * 4)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: sampleSide,
                      height: sampleSide,
                      bitsPerComponent: 8,
                      bytesPerRow: sampleSide * 4,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            // Averages rather than point-samples, so a small logo on a large canvas still
            // registers in the cell it lands in.
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide))
            return true
        }
        guard didDraw else { return .none }

        var hasVisibleSample = false
        var alphaSum = 0.0
        var premultipliedLumaSum = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[offset + 3]
            if alpha >= visibleAlphaFloor { hasVisibleSample = true }
            alphaSum += Double(alpha)
            premultipliedLumaSum += 0.2126 * Double(pixels[offset])
                + 0.7152 * Double(pixels[offset + 1])
                + 0.0722 * Double(pixels[offset + 2])
        }
        guard hasVisibleSample else { return .nothingVisible }

        let transparentShare = 1 - alphaSum / (255 * Double(sampleSide * sampleSide))
        guard transparentShare >= minimumTransparentShare else { return .none }

        // Premultiplied channels already weigh each sample by its coverage, so this is the mean
        // over what is visible, not diluted by the transparent canvas around it.
        let meanLuma = premultipliedLumaSum / alphaSum
        if meanLuma < darkContentLumaCeiling { return .light }
        if meanLuma > lightContentLumaFloor { return .dark }
        return .none
    }

    private static func mayHaveTransparency(_ cgImage: CGImage) -> Bool {
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }

    /// Edge of the bitmap the decision reads. Decoding is the real cost; this is a 16 KB draw.
    private static let sampleSide = 64
    /// Below this share an image still reads as an opaque picture. Rounded corners stay well
    /// under it (under 3% even at a 50pt radius on the 280pt bubble) and must not gain a card,
    /// which would show as white corners around a dark photo.
    private static let minimumTransparentShare = 0.05
    /// Alpha, out of 255, under which a sample holds nothing anyone could see.
    private static let visibleAlphaFloor: UInt8 = 5
    /// sRGB-encoded luma, 0 to 1, below which content is too dark to read on black. About 2.5:1
    /// against it, the same contrast `lightContentLumaFloor` leaves against white.
    private static let darkContentLumaCeiling = 0.3
    /// sRGB-encoded luma, 0 to 1, above which content is too light to read on white.
    private static let lightContentLumaFloor = 0.65
}
