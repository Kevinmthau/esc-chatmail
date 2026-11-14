#if os(macOS)
import SwiftUI

/// Puts a `MacDraftFileDropView` behind a chat (`View.macDraftFileDrop`), or over a sheet
/// (`View.macDraftFileDropOverlay`).
struct MacDraftFileDropTarget: NSViewRepresentable {
    let acceptsFiles: @MainActor () -> Bool
    let onDropFiles: @MainActor ([URL]) -> Bool
    /// Pasted pictures' files, from the reply field in front of a chat's drop view. A sheet
    /// has no such field and takes none.
    var onPasteImageFiles: @MainActor ([PastedImageFile]) -> Bool = { _ in false }

    func makeNSView(context: Context) -> MacDraftFileDropView {
        let view = MacDraftFileDropView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: MacDraftFileDropView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: MacDraftFileDropView) {
        view.acceptsFiles = acceptsFiles
        view.onDropFiles = onDropFiles
        view.onPasteImageFiles = onPasteImageFiles
    }
}
#endif
