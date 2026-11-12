import Foundation

/// What the Mac's reply field does with the commands its keys become
/// (`docs/mac-imessage-ui-plan.md`, PR 5; `MacReplyTextView`).
///
/// Return sends mail, and a mail send can't be unsent, so every way a Return could send by
/// accident is decided here, in one pure function, and pinned by `ReplyFieldKeyPolicyTests`.
///
/// The field is an `NSTextView`, which hands its delegate the text system's *commands*
/// (`insertNewline:`), not keys. A command arrives only after an input method has had the key,
/// so the Return that confirms a word of Japanese never gets here as `insertNewline:` in the
/// first place. `hasMarkedText` is asked all the same, for an input method that lets one
/// through. Nothing here is on the send path: `.send` only calls the composer's `onSend`,
/// the closure the send button calls, behind the same `canSend` check.
enum ReplyFieldKeyPolicy {
    /// A command the reply field decides for itself. Every other command is the text view's.
    enum Command: Equatable {
        /// `insertNewline:`. Return and Enter, with or without Shift.
        case insertNewline
        /// `insertNewlineIgnoringFieldEditor:`. Option-Return.
        case insertNewlineIgnoringFieldEditor
        /// `insertLineBreak:`. Control-Return.
        case insertLineBreak
        /// `cancelOperation:`. Escape.
        case cancelOperation

        /// The command a selector names, by the selector's name; nil for one the text view
        /// keeps.
        init?(selectorName: String) {
            switch selectorName {
            case "insertNewline:": self = .insertNewline
            case "insertNewlineIgnoringFieldEditor:": self = .insertNewlineIgnoringFieldEditor
            case "insertLineBreak:": self = .insertLineBreak
            case "cancelOperation:": self = .cancelOperation
            default: return nil
            }
        }
    }

    /// What was true of the key and the field when the command arrived.
    struct Context: Equatable {
        /// Shift was down for the key that made the command.
        var isShiftDown: Bool
        /// The key is repeating: it was held down.
        var isKeyRepeat: Bool
        /// The field holds text an input method has not committed yet.
        var hasMarkedText: Bool
        /// The composer would send right now (`ChatReplyBar.canSend`).
        var canSend: Bool
    }

    enum Action: Equatable {
        /// Send the reply, through the composer's `onSend`.
        case send
        /// Add a line to the draft.
        case insertNewline
        /// Commit the input method's marked text, and nothing else.
        case commitMarkedText
        /// Take the command and do nothing.
        case ignore
        /// Take the command and tell the composer Escape was pressed.
        case cancel
    }

    static func action(for command: Command, context: Context) -> Action {
        switch command {
        case .insertNewline:
            // The Return that confirms an input method's word is the input method's. If one
            // reaches the field as a command anyway, it confirms the word: it never sends,
            // and it adds no line.
            if context.hasMarkedText { return .commitMarkedText }
            // Shift-Return adds a line, as in the web app and in Messages. Left to a SwiftUI
            // `TextField`, it submitted (the spike).
            if context.isShiftDown { return .insertNewline }
            // A held Return sends once. The first send empties the field, so a repeat would
            // normally find nothing to send, but a reply restored by a failed send must not go
            // out again because the key was still down.
            if context.isKeyRepeat { return .ignore }
            // Nothing to send, a send already owning the draft, or an attachment still being
            // read: Return does nothing. It never adds a line, so a Return pressed a moment
            // early does not leave a stray blank line in the mail that is then sent.
            return context.canSend ? .send : .ignore
        case .insertNewlineIgnoringFieldEditor, .insertLineBreak:
            // Option-Return and Control-Return add a line. Both insert a plain newline: left
            // alone, Control-Return inserts U+2028, which is not a line ending in mail.
            return context.hasMarkedText ? .commitMarkedText : .insertNewline
        case .cancelOperation:
            // Left alone, Escape in a text view opens the completion list. The field takes it
            // and offers it to the composer, which drops the quoted message if there is one
            // (`ChatComposerPolicy.escapeDropsQuote`). An Escape that reaches the field over
            // marked text was for the input method, and drops nothing.
            return context.hasMarkedText ? .ignore : .cancel
        }
    }
}
