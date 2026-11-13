#if os(macOS)
import SwiftUI

/// Puts a `MacDraftFileDropView` behind a chat (`View.macDraftFileDrop`).
struct MacDraftFileDropTarget: NSViewRepresentable {
    let acceptsFiles: @MainActor () -> Bool
    let onDropFiles: @MainActor ([URL]) -> Bool

    func makeNSView(context: Context) -> MacDraftFileDropView {
        let view = MacDraftFileDropView(frame: .zero)
        view.acceptsFiles = acceptsFiles
        view.onDropFiles = onDropFiles
        return view
    }

    func updateNSView(_ view: MacDraftFileDropView, context: Context) {
        view.acceptsFiles = acceptsFiles
        view.onDropFiles = onDropFiles
    }
}
#endif
