#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
/// Light, dark, or follow the surroundings: UIKit's `UIUserInterfaceStyle` on iOS, so nothing
/// about iOS web views changes. `WKWebView.applyInterfaceStyle(_:)` applies it.
typealias PlatformInterfaceStyle = UIUserInterfaceStyle
#elseif canImport(AppKit)
/// Light, dark, or follow the surroundings, with the case names of UIKit's `UIUserInterfaceStyle`
/// so shared code reads the same on both platforms. `WKWebView.applyInterfaceStyle(_:)` applies it.
enum PlatformInterfaceStyle: Equatable {
    case unspecified
    case light
    case dark

    /// The AppKit appearance to force: Aqua or Dark Aqua, or nil to inherit the window's. CSS
    /// `prefers-color-scheme` follows it, even for a web view in no window (WebKit spike, 2026-11-09).
    var appearance: NSAppearance? {
        switch self {
        case .unspecified:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}
#endif
