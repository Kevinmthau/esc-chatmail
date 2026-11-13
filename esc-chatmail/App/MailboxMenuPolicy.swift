import Foundation

/// Decides what choosing the Mac's mailbox menu commands (`MailboxCommands`) does: whether New
/// Message opens, and which way the read-state command (Command-Shift-U) changes the selected
/// conversations.
enum MailboxMenuPolicy {
    /// What choosing New Message does.
    enum NewMessageChoice: Equatable {
        /// Open the New Message sheet.
        case open
        /// Open nothing. The command beeps, so the choice does not look ignored.
        case refuse
    }

    /// - The focused window has a sheet attached → refuse. New Message is a sheet on that window,
    ///   and a Mac window shows one sheet at a time (`FocusedWindowSheet`): asked for under the
    ///   reader, Participants or the Sign Out… confirmation, it would stay queued, unseen, until
    ///   that sheet closed, and then appear with nothing on screen to explain it. The same rule
    ///   the Sign Out… command follows (`SignOutMenuPolicy.choice`). It covers New Message's own
    ///   sheet too, where a second request has nothing to do.
    /// - Otherwise → open.
    ///
    /// `focusedWindowHasSheet` is read from AppKit at the moment the command is chosen. It must
    /// stay a live read and never become a count of the sheets the app presented: a count that
    /// stuck above zero would leave the command refusing for good.
    ///
    /// The toolbar's New Message button needs no such rule: a window with a sheet attached takes
    /// no clicks. A menu command and its Command-N still arrive.
    static func newMessageChoice(focusedWindowHasSheet: Bool) -> NewMessageChoice {
        focusedWindowHasSheet ? .refuse : .open
    }

    // MARK: - Mark as Read / Mark as Unread

    /// Which way the read-state command changes the conversations it acts on.
    enum ReadStateCommand: Equatable {
        case markRead
        case markUnread
    }

    /// What the read-state command does to conversations with these inbox unread counts, one
    /// count for each conversation it acts on. Nil for none: the command is disabled.
    ///
    /// - Any of them unread → mark as read, which reads the ones that are unread.
    /// - All of them read → mark as unread.
    ///
    /// The rule Mail follows for several selected messages. For one conversation it is the
    /// toggle its row's right-click menu and swipe make
    /// (`ConversationListViewModel.toggleConversationReadState`).
    static func readStateCommand(unreadCounts: [Int]) -> ReadStateCommand? {
        guard !unreadCounts.isEmpty else { return nil }
        return unreadCounts.contains(where: { $0 > 0 }) ? .markRead : .markUnread
    }

    /// Whether the command changes a conversation with this inbox unread count. One that is
    /// already as the command leaves it is passed over: marking a read conversation as read
    /// would queue nothing, and marking an unread one as unread again would too.
    static func changesReadState(_ command: ReadStateCommand, unreadCount: Int) -> Bool {
        switch command {
        case .markRead:
            return unreadCount > 0
        case .markUnread:
            return unreadCount <= 0
        }
    }

    /// The menu item's title, the words the row's right-click menu uses. With nothing to act
    /// on the item is disabled and reads Mark as Unread, as Messages' does.
    static func readStateTitle(for command: ReadStateCommand?) -> String {
        switch command {
        case .markRead:
            return "Mark as Read"
        case .markUnread, nil:
            return "Mark as Unread"
        }
    }
}
