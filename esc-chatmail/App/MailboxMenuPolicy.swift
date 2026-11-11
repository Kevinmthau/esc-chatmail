import Foundation

/// Decides what choosing the Mac's New Message menu command (`MailboxCommands`) does.
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
}
