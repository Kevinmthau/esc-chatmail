#if os(macOS)
import SwiftUI

/// A Done button along the bottom of a Mac sheet that has no control of its own to close it
/// (`MacSheetChrome.sizedWithDoneBar`). On iOS such a sheet is swiped down. A Mac sheet has no
/// such gesture, and with no button and no text field in it Escape does not close it either
/// (measured on macOS 27.2, 2026-11-10), so it would trap the window.
///
/// Return and Escape both press Done, as they do in the Participants sheet. A button answers one
/// shortcut, so the visible one takes Return and `MacSheetEscapeCloses` adds Escape.
///
/// The bottom inset is always applied and filled only when `isShown`
/// (`MacSheetChromeModifier` says why).
struct MacSheetDoneBar: ViewModifier {
    let isShown: Bool
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if isShown {
                HStack {
                    Spacer()
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
                .modifier(MacSheetEscapeCloses())
            }
        }
    }
}
#endif
