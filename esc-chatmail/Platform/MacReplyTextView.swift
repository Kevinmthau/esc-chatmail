#if os(macOS)
import AppKit

/// The text view inside the Mac's reply field (`MacReplyTextField`).
///
/// A subclass to report what a delegate is not told: that it gained or lost the keyboard
/// focus, and that it entered or left a window. The field's keys are decided by its delegate
/// (`MacReplyTextFieldCoordinator`, `ReplyFieldKeyPolicy`).
///
/// And to give away a drag of files. A text view takes one and types the file's path at the
/// pointer (measured on this field, 2026-11-12), which in a reply is never what a dropped file
/// means. The chat behind the field attaches it instead (`MacFileDropForwarder`); where there
/// is no chat to take it the drag is refused. A drag of text is the text view's own, as before.
final class MacReplyTextView: NSTextView {
    /// The view became (`true`) or stopped being (`false`) its window's first responder.
    var onFocusChange: ((Bool) -> Void)?
    /// The view entered a window (`true`) or left one (`false`).
    var onWindowChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { onFocusChange?(true) }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign { onFocusChange?(false) }
        return didResign
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window != nil)
    }

    // MARK: - Dragged files

    private let fileDropForwarder = MacFileDropForwarder()

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropForwarder.draggingEntered(sender, in: window) ?? super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropForwarder.draggingUpdated(sender) ?? super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // A file drag never reached the text view's own `draggingEntered`, so it is not told
        // of the exit either.
        if !fileDropForwarder.draggingExited() {
            super.draggingExited(sender)
        }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDropForwarder.prepareForDragOperation(sender) ?? super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDropForwarder.performDragOperation(sender) ?? super.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if !fileDropForwarder.concludeDragOperation() {
            super.concludeDragOperation(sender)
        }
    }
}
#endif
