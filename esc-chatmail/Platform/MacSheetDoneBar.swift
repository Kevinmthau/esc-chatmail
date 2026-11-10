#if os(macOS)
import SwiftUI

/// A Done button along the bottom of a Mac sheet that has no control of its own to close it
/// (`View.macSheetDoneBar(_:)`). On iOS such a sheet is swiped down; a Mac sheet has no such
/// gesture, so without a button it can only be left with Escape. Escape presses this button.
struct MacSheetDoneBar: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}
#endif
