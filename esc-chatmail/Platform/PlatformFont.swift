#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
/// The app's font type: UIKit's `UIFont` on iOS, so nothing about iOS fonts changes.
typealias PlatformFont = UIFont
#elseif canImport(AppKit)
/// The app's font type: AppKit's `NSFont` on the Mac.
///
/// No extension is needed for the one call the shared code makes:
/// `NSFont.preferredFont(forTextStyle:options:)` imports with a defaulted `options`, so UIKit's
/// spelling, `preferredFont(forTextStyle: .body)`, already compiles against `NSFont` and returns
/// the Mac's Dynamic Type body font.
typealias PlatformFont = NSFont
#endif
