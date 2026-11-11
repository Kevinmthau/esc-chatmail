#if os(macOS)
import SwiftUI

/// The Mac's mailbox menu commands: New Message, Search and Get New Mail. Each does what a
/// control in the window does (`MailboxMenuActions`); none adds a path of its own.
///
/// New Message takes Command-N in place of File > New Window. The app has one window on
/// purpose: `ChatReplyComposerDirectory` lets only the newest composer write a conversation's
/// draft, so two windows on one chat would fight over it.
///
/// Chosen while the focused window has a sheet attached, New Message beeps and opens nothing
/// (`MailboxMenuPolicy.newMessageChoice`). Search and Get New Mail are not checked: neither
/// presents anything.
struct MailboxCommands: Commands {
    @FocusedValue(\.mailboxMenuActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") {
                actions?.chooseNewMessage()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(actions == nil)
        }
        CommandMenu("Mailbox") {
            Button("Get New Mail") {
                actions?.sync()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(actions == nil)

            Button("Search") {
                actions?.search()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(actions == nil)
        }
    }
}
#endif
