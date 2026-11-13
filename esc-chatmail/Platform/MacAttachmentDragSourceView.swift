#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// The view over an attachment in a Mac chat that lets it be dragged out to the Finder or
/// another app (`View.macAttachmentDragSource`).
///
/// An AppKit view, not SwiftUI's `onDrag`, for two reasons. The drag carries a file promise
/// (`MacAttachmentFilePromiseProvider`), which an `onDrag` item provider cannot be. And every
/// attachment view is a `Button`, with which `onDrag` could not be measured here: whether it
/// starts a drag at all over a button, and what it does to the button's click, can only be
/// seen by dragging with the real pointer.
///
/// The view is in front of the attachment, so the left mouse button is its own: a press that
/// moves `AttachmentDragPolicy.dragThreshold` starts the drag, and one released in place is
/// the click the attachment's button would have had, handed on through `onClick`. It is only
/// put over an attachment that has its file, where that click is the button's whole job (the
/// retry control exists only on a failed one). Everything else passes it by: a right-click
/// gets the menu of the views behind it (`menu(for:)`), and the scroll wheel is not handled
/// here at all.
final class MacAttachmentDragSourceView: NSView, NSDraggingSource {
    /// The attachment's file and name, read when a drag starts. Nil where the file is gone.
    var resolveItem: @MainActor () -> AttachmentExportItem? = { nil }
    /// A click on the attachment.
    var onClick: @MainActor () -> Void = {}
    /// Starts the dragging session. A property so the tests never start one: a session is
    /// the window server's, and follows the real pointer.
    var beginSession: @MainActor (MacAttachmentDragSourceView, [NSDraggingItem], NSEvent) -> Void = { view, items, event in
        view.beginDraggingSession(with: items, event: event, source: view)
    }

    /// Where the button went down, in the window. Nil when no press is in progress.
    private var pressLocation: NSPoint?
    private var didStartDrag = false

    /// The side of the file icon a drag shows under the pointer.
    static let dragIconSide: CGFloat = 64

    /// A press on the attachment never moves the window, whatever the window allows.
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    // MARK: - The left mouse button

    override func mouseDown(with event: NSEvent) {
        pressLocation = event.locationInWindow
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressLocation, !didStartDrag,
              AttachmentDragPolicy.startsDrag(from: pressLocation, to: event.locationInWindow) else {
            return
        }
        // Set before the file is looked for: a press that moved this far is not a click,
        // with or without a file to carry.
        didStartDrag = true
        guard let item = resolveItem() else { return }
        beginSession(self, [draggingItem(for: item, pressedAt: pressLocation)], event)
    }

    override func mouseUp(with event: NSEvent) {
        // A dragging session takes the release itself, so after a drag this is not called and
        // the next press starts clean in `mouseDown`.
        guard pressLocation != nil else { return }
        pressLocation = nil
        let releasedInside = bounds.contains(convert(event.locationInWindow, from: nil))
        if AttachmentDragPolicy.isClick(didStartDrag: didStartDrag, releasedInside: releasedInside) {
            onClick()
        }
    }

    // MARK: - Everything else

    /// The menu of the views behind this one: the attachment's own
    /// (`MacAttachmentExportMenu`), which SwiftUI answers with from its hosting view. This
    /// view has none, and a right-click on it must not open nothing.
    override func menu(for event: NSEvent) -> NSMenu? {
        var ancestor = superview
        while let view = ancestor {
            if let menu = view.menu(for: event) {
                return menu
            }
            ancestor = view.superview
        }
        return nil
    }

    // MARK: - The drag

    /// One dragged item: the promise, drawn as the file's icon under the pointer.
    func draggingItem(for item: AttachmentExportItem, pressedAt pressLocation: NSPoint) -> NSDraggingItem {
        let draggingItem = NSDraggingItem(pasteboardWriter: MacAttachmentFilePromiseProvider(item: item))
        let pathExtension = AttachmentExportPolicy.splitExtension(of: item.filename).pathExtension
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: pathExtension) ?? .data)
        let center = convert(pressLocation, from: nil)
        let frame = NSRect(
            x: center.x - Self.dragIconSide / 2,
            y: center.y - Self.dragIconSide / 2,
            width: Self.dragIconSide,
            height: Self.dragIconSide
        )
        draggingItem.setDraggingFrame(frame, contents: icon)
        return draggingItem
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        sourceOperationMask(for: context)
    }

    /// What a drop may do with the attachment in each place: copy it outside the app, nothing
    /// inside it (`AttachmentDragPolicy.allowsCopy`).
    func sourceOperationMask(for context: NSDraggingContext) -> NSDragOperation {
        AttachmentDragPolicy.allowsCopy(outsideApplication: context == .outsideApplication) ? .copy : []
    }
}
#endif
