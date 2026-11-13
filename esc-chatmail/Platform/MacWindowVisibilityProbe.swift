#if os(macOS)
import AppKit
import SwiftUI

/// Hands out a way to ask, later, whether the window this view is in is on screen. Put it in
/// the background of a window's content.
///
/// The answer is read from AppKit when it is asked for, through the view this makes, and not
/// kept from `onAppear` and `onDisappear`: whether SwiftUI calls those for a Settings window
/// that is closed and opened again was not measured. A closed window is ordered out, so it
/// is not visible; a view SwiftUI has taken down has no window. Both read as off screen.
struct MacWindowVisibilityProbe: NSViewRepresentable {
    /// Called once, when the view is made, with the question to keep.
    let onProbe: @MainActor (@escaping @MainActor () -> Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onProbe(Self.isOnScreen(windowOf: view))
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Whether `view`'s window is on screen, asked when the returned closure is called. Holds
    /// `view` weakly: a view that has gone has no window to show anything on.
    static func isOnScreen(windowOf view: NSView) -> @MainActor () -> Bool {
        { [weak view] in
            view?.window?.isVisible ?? false
        }
    }
}
#endif
