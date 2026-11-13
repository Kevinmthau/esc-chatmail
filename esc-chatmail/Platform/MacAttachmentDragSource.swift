#if os(macOS)
import SwiftUI

/// Puts a `MacAttachmentDragSourceView` over an attachment (`View.macAttachmentDragSource`).
struct MacAttachmentDragSource: NSViewRepresentable {
    let resolveItem: @MainActor () -> AttachmentExportItem?
    let onClick: @MainActor () -> Void

    func makeNSView(context: Context) -> MacAttachmentDragSourceView {
        let view = MacAttachmentDragSourceView(frame: .zero)
        view.resolveItem = resolveItem
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: MacAttachmentDragSourceView, context: Context) {
        view.resolveItem = resolveItem
        view.onClick = onClick
    }
}
#endif
