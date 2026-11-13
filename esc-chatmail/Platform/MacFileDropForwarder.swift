#if os(macOS)
import AppKit

/// Hands a file drag that AppKit gave to a view in front of a chat to the chat's own drop view
/// (`MacDraftFileDropView`), for the two kinds of view that take drags themselves: the reply
/// field's text view and an email's web view.
///
/// Each of those views owns one forwarder and asks it at every step of a drag. A nil answer
/// means the drag carries no files and is the asking view's to decide: the text view takes
/// dragged text as before, and a web view refuses it. A drag of files is answered here for good,
/// with a refusal where the window has no chat to take them, so neither view ever does what it
/// would have done with a file: type its path, or load it.
@MainActor
final class MacFileDropForwarder {
    /// The drop view the drag in progress is being handed to. Looked up once, as the drag
    /// comes in: it is a walk over the window's views, and a drag updates on every move.
    private weak var dropView: MacDraftFileDropView?
    /// Whether the drag in progress carries files, and so is answered here.
    private(set) var isForwarding = false

    func draggingEntered(_ sender: NSDraggingInfo, in window: NSWindow?) -> NSDragOperation? {
        guard MacDraftFileDropView.carriesFiles(sender.draggingPasteboard) else {
            end()
            return nil
        }
        isForwarding = true
        dropView = MacDraftFileDropView.dropView(in: window, at: sender.draggingLocation)
        return dropView?.draggingEntered(sender) ?? []
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation? {
        guard isForwarding else { return nil }
        return dropView?.draggingUpdated(sender) ?? []
    }

    /// Returns whether the drag was one answered here.
    func draggingExited() -> Bool {
        let wasForwarding = isForwarding
        end()
        return wasForwarding
    }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool? {
        guard isForwarding else { return nil }
        return dropView?.prepareForDragOperation(sender) ?? false
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool? {
        guard isForwarding else { return nil }
        return dropView?.performDragOperation(sender) ?? false
    }

    /// The drag is over. Returns whether it was one answered here.
    func concludeDragOperation() -> Bool {
        let wasForwarding = isForwarding
        end()
        return wasForwarding
    }

    private func end() {
        isForwarding = false
        dropView = nil
    }
}
#endif
