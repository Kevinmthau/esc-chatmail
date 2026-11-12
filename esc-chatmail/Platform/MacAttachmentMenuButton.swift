#if os(macOS)
import SwiftUI

/// The "+" button beside the Mac's reply field: a glass circle that opens a menu of the two
/// attachment pickers, as Messages' does (`AttachmentPickerStyle.plusMenu`).
///
/// The pickers themselves, and what happens to what they return, are `AttachmentPicker`'s.
struct MacAttachmentMenuButton: View {
    let diameter: CGFloat
    let onChoosePhotos: () -> Void
    let onChooseFiles: () -> Void

    var body: some View {
        Menu {
            Button(action: onChoosePhotos) {
                SwiftUI.Label("Photos", systemImage: "photo")
            }
            Button(action: onChooseFiles) {
                SwiftUI.Label("Files", systemImage: "paperclip")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: diameter * 0.47, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // The label's size and no more, so the button and the field beside it share a row
        // height.
        .frame(width: diameter, height: diameter)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("Add an attachment")
        .accessibilityLabel("Add attachment")
    }
}
#endif
