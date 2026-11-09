import SwiftUI

/// The UIKit system colors the views use, as SwiftUI colors on both platforms. Each is the
/// `PlatformColor` of the same name, so on iOS it is exactly the `Color(UIColor.…)` the views wrote
/// before, and on the Mac it is the counterpart described on `PlatformColor`.
extension Color {
    static let systemBackground = Color(PlatformColor.systemBackground)
    static let secondarySystemBackground = Color(PlatformColor.secondarySystemBackground)
    static let systemGroupedBackground = Color(PlatformColor.systemGroupedBackground)
    static let systemGray = Color(PlatformColor.systemGray)
    static let systemGray3 = Color(PlatformColor.systemGray3)
    static let systemGray4 = Color(PlatformColor.systemGray4)
    static let systemGray5 = Color(PlatformColor.systemGray5)
    static let systemGray6 = Color(PlatformColor.systemGray6)
    static let systemBlue = Color(PlatformColor.systemBlue)
    static let tertiarySystemFill = Color(PlatformColor.tertiarySystemFill)
    static let separator = Color(PlatformColor.separator)
    static let tertiaryLabel = Color(PlatformColor.tertiaryLabel)
    static let placeholderText = Color(PlatformColor.placeholderText)
}
