import SwiftUI

/// What a row draws beside and around its bubble, per style. Pure, so `MessageBubble`'s body
/// holds no style or platform check.
enum MessageBubbleRowPolicy {
    /// What stands at the leading edge of an incoming row.
    enum LeadingSlot: Equatable {
        /// Nothing: the bubble starts at the row's edge.
        case none
        case avatar
        /// The avatar's width, empty, so the bubbles of a run line up under the one that has
        /// the avatar.
        case avatarPlaceholder
    }

    static func leadingSlot(
        style: MessageBubbleStyle,
        isOneToOneConversation: Bool,
        endsRun: Bool
    ) -> LeadingSlot {
        guard style.showAvatar else { return .none }
        // Messages shows no avatar in a one-to-one chat: the header says who it is.
        if style == .mac, isOneToOneConversation { return .none }
        return endsRun ? .avatar : .avatarPlaceholder
    }

    /// Whether an incoming row names its sender above the bubble. Only in a group; the Mac
    /// names the sender once, above the first bubble of a run.
    static func showsSenderName(
        style: MessageBubbleStyle,
        isFromMe: Bool,
        isGroupConversation: Bool,
        startsRun: Bool
    ) -> Bool {
        guard !isFromMe, style.showSenderName, isGroupConversation else { return false }
        return style == .mac ? startsRun : true
    }

    /// The tail of a row's bubble, or nil for none: on the last bubble of a run, at the bottom
    /// corner on the row's own side.
    static func tail(
        style: MessageBubbleStyle,
        isFromMe: Bool,
        endsRun: Bool,
        layoutDirection: LayoutDirection
    ) -> BubbleShape.Tail? {
        guard style.bubbleTailWidth > 0, endsRun else { return nil }
        // An outgoing row is at the trailing edge, which is the left in a right-to-left layout.
        let isOnTheRight = isFromMe == (layoutDirection == .leftToRight)
        return isOnTheRight ? .right : .left
    }
}
