#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
/// What GoogleSignIn presents its interactive sign-in from: a view controller on iOS
/// (`signIn(withPresenting: UIViewController, …)`).
typealias PresentationAnchor = UIViewController
#elseif canImport(AppKit)
/// What GoogleSignIn presents its interactive sign-in from: a window on the Mac
/// (`signIn(withPresenting: NSWindow, …)`), which supplies the presentation context for its
/// `ASWebAuthenticationSession`. The flow then opens the browser and returns through the app's
/// URL scheme and the existing `onOpenURL` handler.
typealias PresentationAnchor = NSWindow
#endif
