#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import WebKit

/// A `WKWebView` subclass that reports layout/window changes so email WebView coordinators can
/// (re)load content once they have a window and valid dimensions.
///
/// Shared by preview WebViews, the full reader, the snapshot renderer, and the pre-rendered
/// `FullEmailWebViewManager` so a warmed full-reader instance can be adopted without losing its
/// layout callbacks.
///
/// On the Mac, `setFrameSize(_:)` and `viewDidMoveToWindow()` stand in for UIKit's
/// `layoutSubviews()` and `didMoveToWindow()`. `layout()` would also fire, but the WebKit spike
/// saw it for only about a quarter of SwiftUI's frame changes.
///
/// `acceptsFirstMouse(for:)` is deliberately not overridden: in an inactive Mac window the first
/// click on the full reader only activates the window, as in most Mac apps, so a click meant to
/// bring the window forward cannot open a link. Returning true would let that click reach the
/// page as `.linkActivated` (spike, 2026-11-09). Decided 2026-11-11: it stays this way
/// (`docs/mac-app-plan.md`, decision 8).
///
/// On the Mac it also takes no drop. A `WKWebView` is the destination of any drag over it, with
/// `hitTest(_:)` returning nil and its drag types unregistered alike, and it loads a dropped
/// file in place of its page: a preview card's delegate allowed that load, which arrives as
/// `.other`, the type of the card's own first load (measured in the sandboxed test host,
/// 2026-11-12). So no drag reaches WebKit. A drag of files goes to the chat behind the web view,
/// which attaches them to the reply (`MacFileDropForwarder`); every other drag, and a file drag
/// where there is no chat (the reader's sheet), is refused.
final class LayoutAwareWKWebView: WKWebView {
    var onLayoutChange: ((WKWebView) -> Void)?

    #if !canImport(UIKit) && canImport(AppKit)
    /// False once `makeNonInteractive()` runs: `hitTest(_:)` then returns nil.
    private var acceptsUserInput = true
    #endif

    /// Turns off every kind of input for a web view that only displays content: taps or clicks,
    /// text selection, context menus and scrolling, so the scroll view around it (the chat
    /// transcript) gets the gestures instead.
    ///
    /// On the Mac, `hitTest(_:)` returns nil, which also keeps every wheel and trackpad event away
    /// from the web view. Without it, a preview card swallows transcript scrolling: in the WebKit
    /// spike a 150 pt trackpad gesture over a card moved the transcript 0 pt instead of 150.
    func makeNonInteractive() {
        #if canImport(UIKit)
        scrollView.isScrollEnabled = false
        scrollView.bounces = false
        isUserInteractionEnabled = false
        #elseif canImport(AppKit)
        acceptsUserInput = false
        #endif
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutChange?(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onLayoutChange?(self)
    }
    #elseif canImport(AppKit)
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayoutChange?(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onLayoutChange?(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsUserInput else {
            return nil
        }
        return super.hitTest(point)
    }

    // MARK: - Drags (none reaches WebKit)

    private let fileDropForwarder = MacFileDropForwarder()

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropForwarder.draggingEntered(sender, in: window) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropForwarder.draggingUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        _ = fileDropForwarder.draggingExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDropForwarder.prepareForDragOperation(sender) ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDropForwarder.performDragOperation(sender) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        _ = fileDropForwarder.concludeDragOperation()
    }
    #endif
}
