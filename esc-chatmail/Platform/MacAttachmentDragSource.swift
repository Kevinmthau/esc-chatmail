#if os(macOS)
import SwiftUI

/// Puts a `MacAttachmentDragSourceView` over an attachment (`View.macAttachmentDragSource`).
struct MacAttachmentDragSource: NSViewRepresentable {
    let resolveItem: @MainActor () -> AttachmentExportItem?
    let onClick: @MainActor () -> Void
    let takesMouse: @MainActor () -> Bool

    func makeNSView(context: Context) -> MacAttachmentDragSourceView {
        let view = MacAttachmentDragSourceView(frame: .zero)
        view.resolveItem = resolveItem
        view.onClick = onClick
        view.takesMouse = takesMouse
        return view
    }

    func updateNSView(_ view: MacAttachmentDragSourceView, context: Context) {
        view.resolveItem = resolveItem
        view.onClick = onClick
        view.takesMouse = takesMouse
    }
}
#endif
