import SwiftUI

/// Whether the window a view is in is the one the user is working in.
///
/// On the Mac this is SwiftUI's `appearsActive`: false while another app is in front or another
/// window has the focus. A Mac chat stays in the window's chat column for as long as its row is
/// selected, so "the chat is on screen" says nothing about whether anyone is looking at it; mail
/// that arrives while the app sits behind other windows must not be marked read
/// (`ChatView.isChatActiveAndUncovered`).
///
/// Always true on iOS, where the scene phase already covers this: an iPhone app that is not in
/// front is not active.
///
/// A `DynamicProperty` so a view declares it as a stored property and reads `value` in `body`,
/// without a platform check of its own.
struct WindowAppearsActive: DynamicProperty {
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    #endif

    var value: Bool {
        #if os(macOS)
        appearsActive
        #else
        true
        #endif
    }
}
