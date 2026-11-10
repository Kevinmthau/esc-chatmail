#if os(macOS)
import SwiftUI

/// Makes Escape close the Mac sheet it is applied in (`View.macSheetClosesOnEscape()`), for a
/// sheet whose visible Done button answers Return.
///
/// A SwiftUI button answers one keyboard shortcut, so the second key needs a second control:
/// a button nobody can see, click, focus or hear named, which only carries the shortcut. It sits
/// in the background, where it takes no space in the layout (measured on macOS 27.2,
/// 2026-11-10: the sheet draws the same with and without it, and Escape presses it).
struct MacSheetEscapeCloses: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.background {
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .focusable(false)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
#endif
