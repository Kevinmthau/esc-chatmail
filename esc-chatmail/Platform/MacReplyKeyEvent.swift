#if os(macOS)
import AppKit

/// What the Mac's reply field needs to know of the key being handled when one of its commands
/// arrives (`ReplyFieldKeyPolicy.Context`).
///
/// The text system hands the field a command (`insertNewline:`), not the key that made it, and
/// Return and Shift-Return make the same command. The key is the event the app is handling.
struct MacReplyKeyEvent: Equatable {
    var isShiftDown: Bool
    var isRepeat: Bool

    /// The key the app is handling now. A command that did not come from a key press (a menu
    /// item, a test) reads as an unshifted key that is not repeating.
    @MainActor
    static func current() -> MacReplyKeyEvent {
        guard let event = NSApp.currentEvent, event.type == .keyDown else {
            return MacReplyKeyEvent(isShiftDown: false, isRepeat: false)
        }
        return MacReplyKeyEvent(
            isShiftDown: event.modifierFlags.contains(.shift),
            isRepeat: event.isARepeat
        )
    }
}
#endif
