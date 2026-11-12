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
///
/// A bare 1 does not say what it counts, and on a mail app's toolbar it reads as one unread
/// message. So the button also names the filter that is on: as its accessibility value, which
/// VoiceOver reads after the button's label, and as its tooltip.
///
/// Not checked with VoiceOver: whether it reads the badge's number as well as this value.
enum MacSidebarFilterBadgePolicy {
    static func badgeCount(for filter: ConversationFilter) -> Int {
        filter == .all ? 0 : 1
    }

    /// The button's accessibility value: the filter that is on, in the word the menu shows for
    /// it. Given for All as well, as a pop-up button reads its current choice whatever it is.
    static func spokenValue(for filter: ConversationFilter) -> String {
        filter.rawValue
    }

    /// The button's tooltip. With a filter on it says the list is showing only part of the
    /// mailbox, which is what the badge is there to say.
    static func helpText(for filter: ConversationFilter) -> String {
        filter == .all ? "Filter conversations" : "Showing only: \(filter.rawValue)"
    }
}
