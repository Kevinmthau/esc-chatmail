#if os(macOS)
import AppKit
import SwiftUI
import XCTest

/// A SwiftUI view mounted in a window that is never shown, for the Mac-plan suites that ask
/// AppKit about real views: which view a point hits, which menu a right-click opens, what a
/// view does with an event it is handed.
///
/// One copy, shared: `MacAttachmentExportMenuTests`, `MacAttachmentDragSourceViewTests` and
/// `MacDraftFileDropViewTests` each had their own window, view lookup, event and menu reading,
/// and a change to how a view is mounted had to be made in each.
///
/// HONEST SCOPE: the window (`XCTestCase.makeTestHostWindow()`) is far off screen and never
/// ordered in, so nothing is drawn for
/// the user and no event comes from the pointer. A test hands a view its events directly,
/// which is what AppKit does once its hit test has chosen the view.
@MainActor
final class MacOffscreenHost {
    let window: NSWindow
    let hostingView: NSHostingView<AnyView>

    /// - Parameter window: The window to mount in, from `XCTestCase.makeTestHostWindow()`,
    ///   which is where the suite's one definition of an off-screen window is.
    init(window: NSWindow, size: CGSize, rootView: some View) {
        self.window = window
        window.setContentSize(size)
        hostingView = NSHostingView(rootView: AnyView(rootView))
        hostingView.frame = NSRect(origin: .zero, size: size)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
    }

    /// Lets SwiftUI finish an update: it builds its AppKit views, and runs the `onChange`
    /// actions it owes, on a later turn of the run loop.
    func settle(for seconds: TimeInterval = 0.2) {
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        hostingView.layoutSubtreeIfNeeded()
    }

    /// Runs the run loop until a view of `type` is in the hierarchy, or `timeout` has passed.
    @discardableResult
    func waitForView<T: NSView>(_ type: T.Type, timeout: TimeInterval = 5) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while first(type) == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        hostingView.layoutSubtreeIfNeeded()
        return first(type)
    }

    /// The first view of `type` in the hierarchy, front to back as `subviews` lists them.
    func first<T: NSView>(_ type: T.Type) -> T? {
        Self.first(type, in: hostingView)
    }

    /// The view AppKit's hit test chooses at `point`, in window coordinates (y up).
    func hitView(at point: NSPoint) -> NSView? {
        hostingView.hitTest(point)
    }

    /// A mouse event at `point`, in window coordinates.
    func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }

    /// The menu the hosting view answers a right-click at `point` with: the SwiftUI context
    /// menu the user would see there. Nil where there is none.
    func menu(at point: NSPoint) throws -> NSMenu? {
        hostingView.menu(for: try mouse(.rightMouseDown, at: point))
    }

    /// A menu's entries top to bottom, each with whether it can be chosen; a separator is
    /// "---". Empty for no menu.
    func entries(of menu: NSMenu?) -> [String] {
        guard let menu else { return [] }
        menu.update()
        return menu.items.map {
            $0.isSeparatorItem ? "---" : "\($0.title):\($0.isEnabled ? "on" : "off")"
        }
    }

    /// Chooses the entry titled `title` of the menu at `point`, as a click on it would.
    func choose(_ title: String, at point: NSPoint) throws {
        let menu = try XCTUnwrap(try menu(at: point), "No menu at \(point)")
        let index = menu.indexOfItem(withTitle: title)
        XCTAssertGreaterThanOrEqual(index, 0, "No \"\(title)\" in \(menu.items.map(\.title))")
        guard index >= 0 else { return }
        menu.performActionForItem(at: index)
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    private static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T {
            return match
        }
        for subview in view.subviews {
            if let match = first(type, in: subview) {
                return match
            }
        }
        return nil
    }
}
#endif
