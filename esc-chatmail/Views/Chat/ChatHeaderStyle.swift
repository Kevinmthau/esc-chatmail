import Foundation

/// How a chat shows whose it is, above its transcript (`docs/mac-imessage-ui-plan.md`, PR 3).
///
/// `ChatView` takes one as a required argument, so each presenter names its own and neither
/// platform gets the other's by default: the iOS list pushes a chat with `.navigationTitle`, and
/// the Mac's chat column shows one with `.avatarOverNameCapsule(.mac)`. What each style draws is
/// `ChatHeaderPolicy`'s to say, so `ChatView`'s body holds no platform check.
enum ChatHeaderStyle: Equatable {
    /// The conversation's name as the navigation bar's title: the iOS chat, as it was before a
    /// chat had a header style.
    case navigationTitle
    /// Messages' header on the Mac: the conversation's avatar in the window's toolbar, and its
    /// name in a capsule in a bar under the toolbar, at the sizes given.
    case avatarOverNameCapsule(ChatHeaderMetrics)
}
