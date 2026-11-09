/// iOS's light and dark values for the system colors the views use that AppKit has no counterpart
/// for: the background levels and the gray ladder. `PlatformColor` rebuilds them from this on the
/// Mac, so the app's surfaces keep the colors they were designed in. `HTMLDisplayWrapper.Theme`
/// hardcodes two of them (#f2f2f7 and #1c1c1e) as the HTML canvas, and a different gray there would
/// show as a seam around every preview card.
///
/// Compiled on both platforms so the iOS suite can check every entry against UIKit's own colors
/// (`IOSSystemColorPaletteTests`).
enum IOSSystemColorPalette {
    /// One color's sRGB values, as 0xRRGGBB, in the light and dark appearances.
    struct Entry: Equatable {
        let light: UInt32
        let dark: UInt32
    }

    static let systemBackground = Entry(light: 0xFFFFFF, dark: 0x000000)
    static let secondarySystemBackground = Entry(light: 0xF2F2F7, dark: 0x1C1C1E)
    static let systemGroupedBackground = Entry(light: 0xF2F2F7, dark: 0x000000)
    static let systemGray3 = Entry(light: 0xC7C7CC, dark: 0x48484A)
    static let systemGray4 = Entry(light: 0xD1D1D6, dark: 0x3A3A3C)
    static let systemGray5 = Entry(light: 0xE5E5EA, dark: 0x2C2C2E)
    static let systemGray6 = Entry(light: 0xF2F2F7, dark: 0x1C1C1E)
}
