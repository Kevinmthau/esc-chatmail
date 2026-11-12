import Foundation

/// How a chat draws its reply composer (`docs/mac-imessage-ui-plan.md`, PR 5).
///
/// `ChatView` takes one as a required argument, like its header and bubble styles, so each
/// presenter names its own and neither platform gets the other's by default: the iOS list
/// pushes a chat with `.bar`, and the Mac's chat column shows one with `.floating(.mac)`. What
/// each style draws and does is `ChatComposerPolicy`'s to say, so no view checks the platform.
///
/// The style changes the composer's drawing and its keys, never its structure: in both it is
/// the overlay at the bottom of the transcript whose measured height feeds
/// `ChatBottomInsetPolicy`, and both send through the one `onSend` closure.
enum ChatComposerStyle: Equatable {
    /// The iPhone's reply bar: a divider, an opaque bar, the two attachment buttons, the field
    /// and a send button beside it. The chat as it was before a chat had a composer style.
    case bar
    /// Messages' composer on the Mac: no divider and no opaque bar, a "+" button that opens a
    /// menu of the attachment pickers, a capsule field in which Return sends, an emoji button
    /// and, while there is something to send, a send arrow inside the field.
    case floating(ChatComposerMetrics)
}
