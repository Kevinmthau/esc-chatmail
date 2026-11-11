// Makes the macOS app icon images from the iOS one.
//
// Usage: swift Scripts/make-mac-app-icon.swift [<source.png> [<output-directory>]]
//
// With no arguments it reads "esc app icon.png" in the app's AppIcon set and writes
// mac-icon-<pixels>.png beside it. Run it again whenever the iOS image changes. It needs the
// Xcode toolchain: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift ...
//
// An iOS icon is a full square that the system masks. A macOS icon in an AppIcon set draws its
// own shape: on a 1024-pixel canvas, a rounded square 824 pixels wide, centered, with
// continuous corners of radius 185.4, and a drop shadow under it (black at 30%, 10 pixels
// down, blurred by 10). Those are the proportions of Apple's macOS icon template. They were
// measured from the icons of apps installed on a Mac running macOS 27.2, where this script's
// full-size output has the same edges and the same shadow, pixel for pixel in alpha, as an
// icon made from the template.
//
// The sizes are 16, 32, 64, 128, 256, 512 and 1024 pixels, which cover the set's ten slots:
// 16, 32, 128, 256 and 512 points at 1x and 2x.
//
// macOS 26 and later redraw every app icon in the system's own shape. They check each size of
// an icon like this one against the template first, and a size that does not match is drawn
// small on a gray plate. Seen on macOS 27.2: a 16-pixel image scaled down with Core Graphics'
// high-quality interpolation, whose edge came out softer than the shape's true coverage, got
// the plate, and the same image scaled as below did not. So keep the scaling exact.
import AppKit
import SwiftUI

let canvas = 1024
let bodyInset: CGFloat = 100
let bodySide: CGFloat = 824
let cornerRadius: CGFloat = 185.4
let shadowOffsetDown: CGFloat = 10
let shadowBlur: CGFloat = 10
let shadowOpacity: CGFloat = 0.3
let pixelSizes = [16, 32, 64, 128, 256, 512, 1024]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
let iconSet = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../esc-chatmail/Resources/Assets.xcassets/AppIcon.appiconset")
    .standardizedFileURL
let sourceURL = arguments.count > 1
    ? URL(fileURLWithPath: arguments[1])
    : iconSet.appendingPathComponent("esc app icon.png")
let outputDirectory = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : iconSet

guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fail("Cannot read \(sourceURL.path)")
}
guard source.width == source.height, source.width >= Int(bodySide) else {
    fail("The source must be square and at least \(Int(bodySide)) pixels wide; it is \(source.width)x\(source.height).")
}
guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { fail("No sRGB color space") }
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

// The full-size icon. The shape's straight edges fall on whole pixels at this size.
var fullSize = [UInt8](repeating: 0, count: canvas * canvas * 4)
guard let context = CGContext(
    data: &fullSize, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: canvas * 4,
    space: sRGB, bitmapInfo: bitmapInfo
) else { fail("Cannot make the bitmap") }
context.interpolationQuality = .high
let body = CGRect(x: bodyInset, y: bodyInset, width: bodySide, height: bodySide)
let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: body).cgPath
// The iOS image, clipped to the shape, is drawn as one layer, so that the shadow is cast by the
// clipped image and nothing else lies under its antialiased edge. Filling the shape first and
// drawing the image over it left a dark fringe there. Core Graphics' y axis points up, so
// "down" is negative.
context.setShadow(
    offset: CGSize(width: 0, height: -shadowOffsetDown),
    blur: shadowBlur,
    color: CGColor(gray: 0, alpha: shadowOpacity)
)
context.beginTransparencyLayer(auxiliaryInfo: nil)
context.addPath(shape)
context.clip()
context.draw(source, in: body)
context.endTransparencyLayer()
context.flush()

func writePNG(_ bytes: [UInt8], pixels: Int) {
    let url = outputDirectory.appendingPathComponent("mac-icon-\(pixels).png")
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(
              width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4,
              space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
              decode: nil, shouldInterpolate: false, intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { fail("Cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("Cannot write \(url.path)") }
    print("wrote \(url.path)")
}

// Every other size is the full-size icon scaled down, each pixel the mean of the block of
// full-size pixels it covers. Every size divides 1024, so the blocks are whole, and the mean of
// premultiplied values is the shape's exact coverage along its edge.
//
// Drawing the shape again at each size is not exact: it antialiases the image's edge and the
// clip's edge on the same pixels wherever 100/1024 of the size is not a whole number, which
// thins the shape.
for pixels in pixelSizes {
    let block = canvas / pixels
    precondition(block * pixels == canvas, "Every size must divide \(canvas)")
    if block == 1 {
        writePNG(fullSize, pixels: pixels)
        continue
    }
    var scaled = [UInt8](repeating: 0, count: pixels * pixels * 4)
    let count = block * block
    for y in 0..<pixels {
        for x in 0..<pixels {
            var sums = [0, 0, 0, 0]
            for blockY in 0..<block {
                let row = ((y * block + blockY) * canvas + x * block) * 4
                for blockX in 0..<block {
                    for channel in 0..<4 {
                        sums[channel] += Int(fullSize[row + blockX * 4 + channel])
                    }
                }
            }
            for channel in 0..<4 {
                scaled[(y * pixels + x) * 4 + channel] = UInt8((sums[channel] + count / 2) / count)
            }
        }
    }
    writePNG(scaled, pixels: pixels)
}
