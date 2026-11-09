#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
/// The app's color type: UIKit's `UIColor` on iOS, so nothing about iOS colors changes.
typealias PlatformColor = UIColor
#elseif canImport(AppKit)
/// The app's color type: AppKit's `NSColor` on the Mac.
///
/// The extension below gives `NSColor` the UIKit system colors the shared code names that AppKit
/// lacks. `systemGray`, `systemBlue`, `tertiarySystemFill`, `clear` and `white` already exist on
/// `NSColor` under the same names.
typealias PlatformColor = NSColor

extension NSColor {
    // The background levels and the gray ladder have no AppKit equivalent, so they keep iOS's
    // values (see `IOSSystemColorPalette` for why those matter).
    static let systemBackground = adaptive(IOSSystemColorPalette.systemBackground)
    static let secondarySystemBackground = adaptive(IOSSystemColorPalette.secondarySystemBackground)
    static let systemGroupedBackground = adaptive(IOSSystemColorPalette.systemGroupedBackground)
    static let systemGray3 = adaptive(IOSSystemColorPalette.systemGray3)
    static let systemGray4 = adaptive(IOSSystemColorPalette.systemGray4)
    static let systemGray5 = adaptive(IOSSystemColorPalette.systemGray5)
    static let systemGray6 = adaptive(IOSSystemColorPalette.systemGray6)

    // Text and separators have the same role on both platforms, so they use AppKit's own colors.
    static var label: NSColor { .labelColor }
    static var tertiaryLabel: NSColor { .tertiaryLabelColor }
    static var placeholderText: NSColor { .placeholderTextColor }
    static var separator: NSColor { .separatorColor }

    /// A color that switches between the entry's two values as the appearance does, as a UIKit
    /// dynamic system color does. High-contrast appearances take the nearest of the two.
    private static func adaptive(_ entry: IOSSystemColorPalette.Entry) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return srgb(isDark ? entry.dark : entry.light)
        }
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif
