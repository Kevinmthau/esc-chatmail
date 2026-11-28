import SwiftUI

/// What VoiceOver and Voice Control are told of a conversation row (architecture review
/// 2026-11, gap-accessibility-architecture#1 and #5).
///
/// The row is one accessibility element: `ConversationRowView` combines its texts (the name,
/// the date and the preview, in that order, as drawn) and hides what has no words, the
/// avatar, the unread dot, the pin and the chevron. What the dot and the pin show is said in
/// the element's value instead. The texts are the row's own, never rebuilt here: a label made
/// from the snapshot would re-derive what the row resolves (the participants' names, the
/// preview's cleanup) and could say something the row does not show.
///
/// The iOS list adds its traits at its call site, never inside the row, which the Mac
/// sidebar's `List(selection:)` shares: there the table row is selectable by itself and is
/// not a button.
enum ConversationRowAccessibilityPolicy {
    /// The row's accessibility value: the state its unread dot and pin show. Empty for a read,
    /// unpinned row, which then says only its texts.
    static func value(isUnread: Bool, isPinned: Bool) -> String {
        [isUnread ? "Unread" : nil, isPinned ? "Pinned" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// The iOS list row's traits: a button, since activating it opens the chat or, while the
    /// list is selecting, toggles its selection; and selected while it is in the selection.
    /// Passed to a modifier that is always applied, so toggling Select changes a value, not
    /// the row's structure (`ConversationListView`'s one structural path).
    static func listRowTraits(isSelecting: Bool, isSelected: Bool) -> AccessibilityTraits {
        var traits: AccessibilityTraits = .isButton
        if isSelecting && isSelected {
            traits.formUnion(.isSelected)
        }
        return traits
    }
}
