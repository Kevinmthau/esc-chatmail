#if os(macOS)
import AppKit
#endif

/// What the app was handling when a chat appeared, as far as
/// `ChatComposerPolicy.focusesFieldWhenChatAppears` needs it.
///
/// On the Mac a chat appears because its row in the sidebar was selected, and a chat puts the
/// caret in its reply field unless a key did the selecting. The chat is built while the event
/// that selected the row is still the one being handled, so the kind of that event is read
/// here. Read from the app, not passed down from the sidebar: the chat column is `Equatable` on
/// the selection alone (`MacMailboxDetail`), and how the row was selected is no part of what
/// it shows.
///
/// Not seen in the app: that the selecting event is still current when the chat's `onAppear`
/// runs was not measured (`docs/mac-imessage-ui-plan.md`, "PR 5 as built"). If it is not, a
/// click reads as `.other`, which focuses the field all the same, and an arrow key that reads
/// as `.other` would take the focus from the sidebar's list.
enum ChatAppearanceTrigger {
    @MainActor
    static func current() -> ChatComposerPolicy.AppearanceTrigger {
        #if os(macOS)
        guard let event = NSApp.currentEvent else { return .other }
        return trigger(isKeyEvent: event.type == .keyDown || event.type == .keyUp)
        #else
        return .other
        #endif
    }

    static func trigger(isKeyEvent: Bool) -> ChatComposerPolicy.AppearanceTrigger {
        isKeyEvent ? .keyPress : .other
    }
}
