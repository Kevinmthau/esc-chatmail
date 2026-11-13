#if os(macOS)
import AppKit

/// A drag in progress, for giving a view's `NSDraggingDestination` methods what AppKit gives
/// them without a pointer or another app: a pasteboard of the test's own and a place in a
/// window.
///
/// HONEST SCOPE: a test hands this to a view directly. Which view AppKit would choose for a
/// drag is not asked here; that was measured once, through AppKit's own private hit test
/// (`docs/mac-app-plan.md`, "Files").
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    private let pasteboard: NSPasteboard
    private let window: NSWindow?
    private let location: NSPoint
    private let sourceOperationMask: NSDragOperation

    init(
        pasteboard: NSPasteboard,
        window: NSWindow?,
        locationInWindow: NSPoint = .zero,
        sourceOperationMask: NSDragOperation = [.copy, .generic, .link]
    ) {
        self.pasteboard = pasteboard
        self.window = window
        self.location = locationInWindow
        self.sourceOperationMask = sourceOperationMask
    }

    /// A pasteboard of the test's own holding `objects`, never the one the user copies to.
    static func pasteboard(holding objects: [NSPasteboardWriting]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("fake-drag-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(objects)
        return pasteboard
    }

    /// A drag of files.
    static func files(
        _ urls: [URL],
        in window: NSWindow?,
        at locationInWindow: NSPoint = .zero,
        sourceOperationMask: NSDragOperation = [.copy, .generic, .link]
    ) -> FakeDraggingInfo {
        FakeDraggingInfo(
            pasteboard: pasteboard(holding: urls.map { $0 as NSURL }),
            window: window,
            locationInWindow: locationInWindow,
            sourceOperationMask: sourceOperationMask
        )
    }

    /// A drag of a run of text.
    static func text(
        _ string: String,
        in window: NSWindow?,
        at locationInWindow: NSPoint = .zero
    ) -> FakeDraggingInfo {
        FakeDraggingInfo(
            pasteboard: pasteboard(holding: [string as NSString]),
            window: window,
            locationInWindow: locationInWindow
        )
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { sourceOperationMask }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}
#endif
