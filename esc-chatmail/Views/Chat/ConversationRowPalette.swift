import SwiftUI

/// The colors a conversation row (`ConversationRowView`) draws its text and marks in.
///
/// A row has two looks. `standard` is the row on the list's own background: every row of the
/// iOS list, and an unselected row of the Mac sidebar. `onSelectionFill` is the Mac sidebar's
/// selected row, which sits on a fill in the system accent color that the sidebar draws
/// (`MacSidebarRowSelectionPolicy`).
///
/// The row sets these colors itself and does not leave them to the list. A Mac list turns a
/// selected row's `primary` and `secondary` text light only while the list has the keyboard
/// focus, and it never changes a color the row names, such as the unread indicator's blue
/// (measured off screen on macOS 27.2; `docs/mac-imessage-ui-plan.md`, "Spike results"). The
/// sidebar's fill stays in the accent color while the caret is in the reply field, so the
/// colors on it have to stay light then too.
struct ConversationRowPalette: Equatable {
    /// The conversation's name. Nil leaves the color to the row's surroundings, which is what
    /// the row did before it had a palette.
    let title: Color?
    /// The timestamp and the preview.
    let secondaryText: Color
    let unreadIndicator: Color
    let pin: Color
    let chevron: Color
    /// The disc and the rings of a group's avatar. They are colors the row draws too, through
    /// `AvatarStackView`, and they were chosen for the list's background.
    let groupAvatar: GroupAvatarColors
}

extension ConversationRowPalette {
    /// The row as it was before it had a palette. `ConversationRowMetricsTests` pins every
    /// field.
    static let standard = ConversationRowPalette(
        title: nil,
        secondaryText: .secondary,
        unreadIndicator: .blue,
        pin: .orange,
        chevron: .tertiaryLabel,
        groupAvatar: .standard
    )

    /// White on the accent color, with the preview and the timestamp a step back from the
    /// name, as `secondary` is from `primary`. The opacity is a first value, not one measured
    /// against Messages.
    static let onSelectionFill = ConversationRowPalette(
        title: .white,
        secondaryText: .white.opacity(0.8),
        unreadIndicator: .white,
        pin: .white,
        chevron: .white.opacity(0.8),
        groupAvatar: .onSelectionFill
    )
}
