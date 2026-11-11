#if os(macOS)
import SwiftUI

/// What the Mac's mailbox menu commands (`MailboxCommands`) do for the focused window.
/// `MacConversationSidebar` publishes it and the commands read it, because the commands live on
/// the scene while the search field, the list's view model and the compose sheet belong to the
/// window's views. Nil while no mailbox is on screen (signed out, or no window focused), which
/// leaves the commands disabled.
struct MailboxMenuActions {
    /// Opens the New Message sheet.
    let newMessage: @MainActor () -> Void
    /// Puts the caret in the sidebar's search field.
    let search: @MainActor () -> Void
    /// Runs a user-initiated sync: the Mac's pull-to-refresh, which has no gesture there.
    let sync: @MainActor () -> Void
}

private struct MailboxMenuActionsKey: FocusedValueKey {
    typealias Value = MailboxMenuActions
}

extension FocusedValues {
    var mailboxMenuActions: MailboxMenuActions? {
        get { self[MailboxMenuActionsKey.self] }
        set { self[MailboxMenuActionsKey.self] = newValue }
    }
}
#endif
