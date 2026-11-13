#if os(macOS)
import AppKit
import SwiftUI

/// What the Mac's mailbox menu commands (`MailboxCommands`) do for the focused window.
/// `MacConversationSidebar` publishes it and the commands read it, because the commands live on
/// the scene while the search field, the list's view model and the compose sheet belong to the
/// window's views. Nil while no mailbox is on screen (signed out, or no window focused), which
/// leaves the commands disabled.
struct MailboxMenuActions {
    /// Opens the New Message sheet. Private so the command can only go through
    /// `chooseNewMessage()`, which may refuse.
    private let newMessage: @MainActor () -> Void
    /// Puts the caret in the sidebar's search field.
    let search: @MainActor () -> Void
    /// Runs a user-initiated sync: the Mac's pull-to-refresh, which has no gesture there.
    let sync: @MainActor () -> Void
    /// What Mark as Read / Mark as Unread would do to the sidebar's selected conversations, as
    /// of the sidebar's last update: the command's title. Nil with nothing to act on, which
    /// disables it.
    let readState: MailboxMenuPolicy.ReadStateCommand?
    /// Marks the sidebar's selected conversations read or unread. Which of the two is decided
    /// again when this is called (`ConversationListViewModel.changeReadState`), so a title a
    /// sync has overtaken does not decide it.
    let changeReadState: @MainActor () -> Void

    init(
        newMessage: @escaping @MainActor () -> Void,
        search: @escaping @MainActor () -> Void,
        sync: @escaping @MainActor () -> Void,
        readState: MailboxMenuPolicy.ReadStateCommand?,
        changeReadState: @escaping @MainActor () -> Void
    ) {
        self.newMessage = newMessage
        self.search = search
        self.sync = sync
        self.readState = readState
        self.changeReadState = changeReadState
    }

    /// The New Message command was chosen. Beeps and opens nothing while the focused window has
    /// a sheet attached (`MailboxMenuPolicy.newMessageChoice`), so a choice made under an open
    /// sheet does not look ignored.
    ///
    /// HONEST SCOPE: nobody has seen this on screen, and no test runs it. Whether SwiftUI keeps
    /// the focused value while a sheet is the key window was not measured. Either answer is
    /// handled: without the value the command is disabled, and with it this refuses.
    @MainActor
    func chooseNewMessage() {
        switch MailboxMenuPolicy.newMessageChoice(focusedWindowHasSheet: FocusedWindowSheet.isAttached) {
        case .open:
            newMessage()
        case .refuse:
            NSSound.beep()
        }
    }
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
