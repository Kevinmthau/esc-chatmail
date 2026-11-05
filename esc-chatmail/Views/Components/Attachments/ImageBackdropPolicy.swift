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
/// thumbnail, which keeps an image within its size limit byte for byte, transparency included.
/// It reads the original when that thumbnail flattened the image onto white, which would leave
/// this policy nothing to find (`ImageProcessor.thumbnailFlattensTransparency`). The grid reads
/// the original, at any size.
enum ImageBackdropPolicy: Equatable {
    /// Reads as an opaque picture, or holds mid-tone content that shows on either background;
    /// whatever is already behind it stays. A round headshot or a colorful logo floated fine on
    /// the transcript and must not gain a square around it.
    case none
    /// Dark content on transparency, which needs a light card.
    case light
    /// Light content on transparency, which needs a dark card.
    case dark
    /// Dark and light content side by side, such as black text beside a bright icon. A white card
    /// loses the light half and a dark card the black one, in either appearance; mid-gray shows both.
    case neutral
    /// No pixel holds anything to see, so no card could help: this is the thumbnail placeholder's
    /// job, in the geometry the attachment's metadata already reserved.
    case nothingVisible

    /// How one sample of the decision bitmap reads against a background.
    private enum SampleTone {
        /// Too transparent to see, so the background shows here.
        case hidden
        case dark
        case mid
        case light
    }

    /// The card to draw behind the image; nil when the backdrop leaves the background alone.
    var matteColor: Color? {
        switch self {
        case .light:
            return .white
        case .dark:
            // The email reader's dark canvas (`HTMLDisplayWrapper.Theme`).
            return Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
        case .neutral:
            // Equally far from black and white: about 4.6:1 against each.
            return Color(red: 0x76 / 255, green: 0x76 / 255, blue: 0x76 / 255)
        case .none, .nothingVisible:
            return nil
        }
    }

    /// The image worth drawing, or nil when the slot should show its placeholder: a loaded image
    /// with nothing to see in it takes the placeholder too. The bubble and the grid both decide
    /// this here, so they can't drift apart.
    func visibleImage(_ image: UIImage?) -> UIImage? {
        self == .nothingVisible ? nil : image
    }

    /// The card behind a visible image: the matte when the image needs one, else the compact
    /// chrome's bubble color. A black logo is no easier to see on the dark bubble, so the matte
    /// wins over the chrome. Nil leaves the transcript showing.
    func cardColor(for presentation: InlineImagePresentationPolicy) -> Color? {
        if let matteColor { return matteColor }
        return presentation == .compact ? MessageBubbleStyle.standard.recipientBubbleColor() : nil
    }

    /// Off the main actor once there is a bitmap to read: a thumbnail decodes lazily, on its
    /// first draw. An image whose format has no alpha channel answers without one.
    ///
    /// A verdict stays with the image it read, so a row scrolling back into view reuses it through
    /// the instance `AttachmentCacheActor` hands back. It can't outlive that instance, or cross an
    /// account or a path change: each of those is a different image.
    ///
    /// Cancelled along with its caller. The draw itself can't be interrupted, so a check that has
    /// started finishes and stores its verdict, sparing the next mount the work. One that hasn't
    /// started answers `.none`, which only a cancelled caller sees, and stores nothing.
    static func resolve(
        for image: UIImage?,
        analyze: @escaping @Sendable (CGImage) -> Self = { ImageBackdropPolicy.resolve(for: $0) }
    ) async -> Self {
        guard let image, let cgImage = image.cgImage, mayHaveTransparency(cgImage) else { return .none }
        if let stored = storedVerdict(for: image) { return stored }
        guard !Task.isCancelled else { return .none }

        let analysis = Task.detached(priority: .userInitiated) { () -> Self in
            guard !Task.isCancelled else { return .none }
            let verdict = analyze(cgImage)
            store(verdict, for: image)
            return verdict
        }
        return await withTaskCancellationHandler {
            await analysis.value
        } onCancel: {
            analysis.cancel()
        }
    }

    /// The verdict already read from this image, if any.
    static func storedVerdict(for image: UIImage) -> Self? {
        objc_getAssociatedObject(image, verdictKey) as? Self
    }

    private static func store(_ verdict: Self, for image: UIImage) {
        objc_setAssociatedObject(image, verdictKey, verdict, .OBJC_ASSOCIATION_RETAIN)
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

        var alphaSum = 0.0
        var visibleCoverage = 0.0
        var tones = [SampleTone](repeating: .hidden, count: sampleSide * sampleSide)
        var toneCoverage = [Double](repeating: 0, count: toneBinCount)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[offset + 3]
            alphaSum += Double(alpha)
            guard alpha >= visibleAlphaFloor else { continue }

            let coverage = Double(alpha)
            visibleCoverage += coverage
            // Per sample, not over the image: the average of black text and a bright icon is a
            // mid-tone that reads fine on anything, while the text itself vanishes on black.
            let luminance = 0.2126 * linearChannel(pixels[offset], alpha: alpha)
                + 0.7152 * linearChannel(pixels[offset + 1], alpha: alpha)
                + 0.0722 * linearChannel(pixels[offset + 2], alpha: alpha)
            if luminance < darkContentLuminanceCeiling {
                tones[offset / 4] = .dark
            } else if luminance > lightContentLuminanceFloor {
                tones[offset / 4] = .light
            } else {
                tones[offset / 4] = .mid
            }
            // The square root spaces the bins roughly as the eye does.
            let toneBin = min(toneBinCount - 1, Int(luminance.squareRoot() * Double(toneBinCount)))
            toneCoverage[toneBin] += coverage
        }
        guard visibleCoverage > 0 else { return .nothingVisible }

        let transparentShare = 1 - alphaSum / (255 * Double(sampleSide * sampleSide))
        guard transparentShare >= minimumTransparentShare else { return .none }

        var darkCoverage = 0.0
        var lightCoverage = 0.0
        for index in samplesExposedToTheBackground(in: tones) {
            let coverage = Double(pixels[index * 4 + 3])
            if tones[index] == .dark {
                darkCoverage += coverage
            } else {
                lightCoverage += coverage
            }
        }

        let topToneCoverage = toneCoverage.sorted(by: >).prefix(flatArtToneCount).reduce(0, +)
        let isFlatArt = topToneCoverage / visibleCoverage >= flatArtMinimumToneShare
        let requiredShare = isFlatArt ? flatArtContentShare : photoContentShare
        switch (darkCoverage / visibleCoverage >= requiredShare, lightCoverage / visibleCoverage >= requiredShare) {
        case (true, true):
            return .neutral
        case (true, false):
            return .light
        case (false, true):
            return .dark
        case (false, false):
            return .none
        }
    }

    /// The dark and light samples whatever is behind the image can actually touch: those on the
    /// image's outer edge or beside a transparent sample, and any sample of the same tone joined to
    /// one of them. This is what tells text beside an icon, which a background can swallow, from a
    /// white glyph inside a red badge, which the badge keeps readable on anything.
    private static func samplesExposedToTheBackground(in tones: [SampleTone]) -> [Int] {
        /// Calls `body` with each in-grid neighbour of `index`, and answers whether `index` is on
        /// the image's outer edge, which is fewer than four neighbours. No array: this runs once per
        /// sample and again per flood step, and building one would allocate on every call.
        @discardableResult
        func forEachNeighbour(of index: Int, _ body: (Int) -> Void) -> Bool {
            let column = index % sampleSide
            var count = 0
            if column > 0 { body(index - 1); count += 1 }
            if column < sampleSide - 1 { body(index + 1); count += 1 }
            if index >= sampleSide { body(index - sampleSide); count += 1 }
            if index < tones.count - sampleSide { body(index + sampleSide); count += 1 }
            return count < 4
        }

        var isExposed = [Bool](repeating: false, count: tones.count)
        var exposed: [Int] = []
        for index in tones.indices where tones[index] == .dark || tones[index] == .light {
            var touchesHidden = false
            let isOnOuterEdge = forEachNeighbour(of: index) { neighbour in
                if tones[neighbour] == .hidden { touchesHidden = true }
            }
            if isOnOuterEdge || touchesHidden {
                isExposed[index] = true
                exposed.append(index)
            }
        }
        var next = 0
        while next < exposed.count {
            let index = exposed[next]
            let tone = tones[index]
            next += 1
            forEachNeighbour(of: index) { neighbour in
                guard !isExposed[neighbour], tones[neighbour] == tone else { return }
                isExposed[neighbour] = true
                exposed.append(neighbour)
            }
        }
        return exposed
    }

    /// Linear light, 0 to 1, of one premultiplied channel in a sample of the given alpha.
    private static func linearChannel(_ premultiplied: UInt8, alpha: UInt8) -> Double {
        let encoded = (Int(premultiplied) * 255 + Int(alpha) / 2) / Int(alpha)
        return linearFromEncoded[min(encoded, 255)]
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
    /// Luminance, 0 to 1, below which content is too dark to read on black: about 2.5:1 against
    /// it. Luminance rather than encoded luma, which would call pure red (5:1 on black) too dark.
    private static let darkContentLuminanceCeiling = 0.073
    /// Luminance, 0 to 1, above which content is too light to read on white: about 2:1 against it.
    /// Lower than the dark side's contrast on purpose, because hue carries saturated colors: bright
    /// orange and sky blue sit near 2.3:1 and are plainly visible on white.
    private static let lightContentLuminanceFloor = 0.45

    /// Flat art keeps its coverage in a few tones, where a photo's spreads across the range. Top
    /// three of sixteen bins: over this share in a logo, well under it in a photo, even one with a
    /// white background and a black jacket.
    private static let toneBinCount = 16
    private static let flatArtToneCount = 3
    private static let flatArtMinimumToneShare = 0.8
    /// The share of a logo's visible content that has to be at risk for a card to be worth it. Text
    /// beside a solid icon holds about this much coverage even when the icon is large. Below it,
    /// a small detail doesn't decide the card; the rest of the logo does.
    private static let flatArtContentShare = 0.15
    /// A photo needs a majority at risk before it gets a card. Its shadows and highlights still read as
    /// part of the picture around them, so a round headshot with dark hair stays card-free.
    private static let photoContentShare = 0.5

    private static let linearFromEncoded: [Double] = (0...255).map { value in
        let encoded = Double(value) / 255
        return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }
    /// Identifies the stored verdict among a `UIImage`'s associated objects, by address only.
    private static let verdictKey = UnsafeRawPointer(
        UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    )
}
