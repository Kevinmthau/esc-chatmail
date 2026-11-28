import SwiftUI

extension View {
    /// The Mac's tooltip for a control that shows only an icon (`help(_:)`), and nothing on iOS.
    ///
    /// For a shared component that names itself with `accessibilityLabel`, as `SendButton` and
    /// the draft attachment's X do: the Mac shows a pointer a tooltip, and iOS has no pointer to
    /// show one to. On iOS `help(_:)` also sets the element's accessibility hint (measured in the
    /// test host on the iOS 27.0 simulator, `AccessibilityNameHostedTests`), so a button named
    /// "Send" was read "Send", then "Send" again as its hint.
    @ViewBuilder
    func macHelp(_ text: String) -> some View {
        #if os(macOS)
        help(text)
        #else
        self
        #endif
    }
}
