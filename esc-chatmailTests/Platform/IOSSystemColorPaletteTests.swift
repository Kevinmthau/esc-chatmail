import XCTest
import UIKit
@testable import esc_chatmail

/// The Mac draws iOS's background and gray system colors from `IOSSystemColorPalette` (AppKit has
/// none of them), so each entry has to be what UIKit itself resolves in that appearance. A failure
/// after an iOS update means Apple changed the palette: update the entry so the Mac follows.
final class IOSSystemColorPaletteTests: XCTestCase {
    func testPaletteEntries_resolvedFromUIKitInLightAndDark_matchUIKitSystemColors() {
        let cases: [(name: String, color: UIColor, entry: IOSSystemColorPalette.Entry)] = [
            ("systemBackground", .systemBackground, IOSSystemColorPalette.systemBackground),
            ("secondarySystemBackground", .secondarySystemBackground, IOSSystemColorPalette.secondarySystemBackground),
            ("systemGroupedBackground", .systemGroupedBackground, IOSSystemColorPalette.systemGroupedBackground),
            ("systemGray3", .systemGray3, IOSSystemColorPalette.systemGray3),
            ("systemGray4", .systemGray4, IOSSystemColorPalette.systemGray4),
            ("systemGray5", .systemGray5, IOSSystemColorPalette.systemGray5),
            ("systemGray6", .systemGray6, IOSSystemColorPalette.systemGray6)
        ]

        for (name, color, entry) in cases {
            XCTAssertEqual(rgbHex(of: color, in: .light), hex(entry.light), "\(name), light")
            XCTAssertEqual(rgbHex(of: color, in: .dark), hex(entry.dark), "\(name), dark")
        }
    }

    /// Strings rather than integers, so a failure prints both values in the palette's notation.
    private func hex(_ value: UInt32) -> String {
        String(format: "%06X", value)
    }

    private func rgbHex(of color: UIColor, in style: UIUserInterfaceStyle) -> String? {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha == 1 else {
            return nil
        }
        let channels = [red, green, blue].map { UInt32(($0 * 255).rounded()) }
        return hex(channels[0] << 16 | channels[1] << 8 | channels[2])
    }
}
