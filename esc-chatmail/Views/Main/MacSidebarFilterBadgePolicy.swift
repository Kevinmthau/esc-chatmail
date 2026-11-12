import Foundation

/// Decides the badge on the Mac sidebar's filter button (`MacConversationSidebar`;
/// `docs/mac-imessage-ui-plan.md`, PR 2).
///
/// The button's icon already changes with the filter, but a list that is missing conversations
/// should say so more plainly than one glyph swapped for another: with a filter on, the sidebar
/// shows only part of the mailbox, and on the Mac it stays that way all day.
///
/// The badge is a count because that is what a toolbar button's badge can be: `badge(_:)` on the
/// button's menu draws a count, and a count of zero draws nothing. The count is the number of
/// filters that are on, which is one or none, since `ConversationFilter` is one choice.
enum MacSidebarFilterBadgePolicy {
    static func badgeCount(for filter: ConversationFilter) -> Int {
        filter == .all ? 0 : 1
    }
}
