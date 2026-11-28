import SwiftUI

/// Every value a transcript row's `MessageBubble` draws from, and nothing else: the bubble is
/// `Equatable` on this alone, and the transcript shows it through `.equatable()`
/// (architecture review 2026-11, chat-transcript-ui#4).
///
/// `ChatMessagesView`'s body runs again on every change its session publishes (each scroll
/// state and coordinator publish, a drag starting and ending, the keyboard moving), and before
/// this every realized row's body ran with it. Now a row's body runs when its inputs change,
/// when its own view model publishes, or when an environment value it reads changes.
///
/// Three things fail silently. A new value the bubble draws goes here, never as a stored
/// property beside it: there it would be left out of `==`, and a row whose other inputs are
/// equal would keep drawing the old value. The bubble's closures are outside on purpose, and a
/// bubble whose inputs are equal keeps the closures of the pass that last changed them, so each
/// must capture only this row's own values and objects that live as long as the chat
/// (`ChatTranscriptRowActions`), and read state when it is called. And `message` is the whole
/// row, never its `loadSignatureComponents`: the stored rich-content verdict is kept out of the
/// load's signature on purpose, and a verdict stamped while the row is mounted must still
/// redraw it, without restarting its load.
struct MessageBubbleInputs: Equatable {
    let message: ChatMessageRowModel
    /// Pre-loaded sender names from batch fetch (avoids N+1 queries)
    let prefetchedSenderName: String?
    /// Presentation mode for threads that collapse multiple emails into one contact.
    let isEffectivelyOneToOneConversation: Bool
    /// Bumps when local contact data changes so sender labels/avatars reload in-place.
    let contactRefreshToken: Int
    /// Where this row sits in its run of bubbles and what it draws above itself
    /// (`ChatTranscriptRunPolicy.placement`): the avatar's and the tail's row, the sender
    /// name's row, the time line.
    let runPlacement: ChatTranscriptRunPlacement
    /// The transcript's width, for a style whose text bubbles take a share of it
    /// (`MessageBubbleStyle.textBubbleMaxWidth`). 0 only for a caller that gives none: the
    /// transcript passes its `GeometryReader`'s width, the width the rows are laid out in, so
    /// a row never wraps its text at one width's cap while it is drawn in another's.
    let transcriptWidth: CGFloat
    /// Whether this row is the conversation's newest message
    /// (`MessageSendStatusLinePolicy.newestRowIndex`); only that row carries the "Sent" receipt.
    let isNewestInTranscript: Bool
    /// Display style configuration
    let style: MessageBubbleStyle
}
