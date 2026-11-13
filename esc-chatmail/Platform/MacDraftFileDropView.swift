#if os(macOS)
import AppKit

/// The view behind a Mac chat that takes files dropped on it (`View.macDraftFileDrop`): a file
/// dragged from the Finder onto the chat column becomes an attachment of the reply.
///
/// An AppKit view, not SwiftUI's `dropDestination`, for two things measured in the sandboxed
/// test host on macOS 27.2 (2026-11-12), by asking the window which view it would give a drag
/// to:
/// - **AppKit views in the chat take the drag first.** A drop goes to the frontmost view under
///   the pointer that is registered for what is dragged, and both a text view and a web view
///   are. The reply field typed the file's path into the draft. An email card's web view took
///   the drop wherever it was dropped on the card, with `hitTest` returning nil and its drag
///   types unregistered alike, and loaded the file in place of the email. Those two hand a
///   file drag to this view instead (`MacFileDropForwarder`), which they could not do to a
///   SwiftUI drop destination: that is a private view.
/// - **It can refuse a drag before the drop.** While the reply cannot take files the pointer
///   shows no copy badge, where a SwiftUI destination can only refuse once the files are let
///   go.
///
/// It sits behind the chat's SwiftUI content and takes no clicks (`hitTest` is nil). A view the
/// drag hit test passes over, because it is not registered for files, leaves the drag to this
/// one behind it.
final class MacDraftFileDropView: NSView {
    /// Whether the reply can take files now (`ChatComposerState.acceptsDroppedFiles`).
    var acceptsFiles: @MainActor () -> Bool = { false }
    /// The files that were dropped. Returns whether the drop was taken.
    var onDropFiles: @MainActor ([URL]) -> Bool = { _ in false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MacDraftFileDropView is built in code")
    }

    /// Nil, so a click on the chat's empty space is never this view's. A drag does not ask
    /// `hitTest`: AppKit finds its destination by frame and registered types.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !operation(for: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Asked again at the drop: a send or an import can have started since the drag came in.
        guard !operation(for: sender).isEmpty else { return false }
        let urls = Self.fileURLs(on: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        return onDropFiles(urls)
    }

    /// What a drop here would do: copy the dragged files into the reply, or nothing
    /// (`DraftFileDropPolicy.takesDrag`).
    ///
    /// Whether AppKit offers a drag to a window under a sheet at all was not measured; the
    /// sheet is asked about either way.
    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        let takesDrag = DraftFileDropPolicy.takesDrag(
            windowHasSheet: window?.attachedSheet != nil,
            carriesFiles: Self.carriesFiles(sender.draggingPasteboard),
            sourceAllowsCopy: sender.draggingSourceOperationMask.contains(.copy),
            acceptsFiles: acceptsFiles()
        )
        return takesDrag ? .copy : []
    }

    // MARK: - The dragged files

    private static let fileURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true
    ]

    /// Whether a drag carries files. A web link or a run of text does not.
    static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: fileURLReadingOptions)
    }

    /// The dragged files, in the pasteboard's order.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLReadingOptions)
        return (objects as? [URL]) ?? []
    }

    // MARK: - Found by the views in front of it

    /// The drop view of `window` under a drag at `locationInWindow`, for a view in front of it
    /// that was given the drag (`MacFileDropForwarder`). Nil where there is none: a window
    /// with no chat open, or a sheet, which is a window of its own.
    static func dropView(in window: NSWindow?, at locationInWindow: NSPoint) -> MacDraftFileDropView? {
        guard let contentView = window?.contentView else { return nil }
        return dropView(under: contentView, at: locationInWindow)
    }

    private static func dropView(under view: NSView, at locationInWindow: NSPoint) -> MacDraftFileDropView? {
        guard !view.isHidden else { return nil }
        if let dropView = view as? MacDraftFileDropView {
            return dropView.convert(dropView.bounds, to: nil).contains(locationInWindow) ? dropView : nil
        }
        // Front to back, as the views are drawn.
        for subview in view.subviews.reversed() {
            if let found = dropView(under: subview, at: locationInWindow) {
                return found
            }
        }
        return nil
    }
}
#endif
