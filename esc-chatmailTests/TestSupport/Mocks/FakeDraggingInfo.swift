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
    private let sequenceNumber: Int

    /// The last sequence number handed out. Read and written on the main thread only, where
    /// every test that makes a drag runs.
    private static var lastSequenceNumber = 0

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
        Self.lastSequenceNumber += 1
        self.sequenceNumber = Self.lastSequenceNumber
    }

    /// A named pasteboard lives in the pasteboard server, not in this process, and stays
    /// there until it is released: without this every drag a test made left one behind for
    /// as long as the user stayed logged in. Only a pasteboard made by `pasteboard(holding:)`
    /// is released, never one a test was handed from elsewhere.
    deinit {
        if pasteboard.name.rawValue.hasPrefix(Self.pasteboardNamePrefix) {
            pasteboard.releaseGlobally()
        }
    }

    static let pasteboardNamePrefix = "fake-drag-"

    /// A pasteboard of the test's own holding `objects`, never the one the user copies to.
    /// The drag it is given to releases it.
    static func pasteboard(holding objects: [NSPasteboardWriting]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("\(pasteboardNamePrefix)\(UUID().uuidString)"))
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
    /// Its own for each drag, as AppKit's is: a view may keep what it learned about a drag
    /// under this number (`MacDraftFileDropView`).
    var draggingSequenceNumber: Int { sequenceNumber }
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
