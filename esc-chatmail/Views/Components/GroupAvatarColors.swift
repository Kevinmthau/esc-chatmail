import SwiftUI

/// The colors of a group's avatar (`GroupAvatarView`) that depend on what the avatar sits on.
///
/// A group's avatar is a disc with up to four small avatars on it, each inside a ring that
/// parts it from the ones it overlaps. The disc and the rings were literals chosen for a list's
/// own background: a disc a shade off it, and rings in its color, near black in a dark window.
/// A selected row of the Mac sidebar sits on the accent color instead, in a light window and a
/// dark one, and a list never changes a color a view names. So the row's palette names these
/// two as it names the row's other colors (`ConversationRowPalette`).
struct GroupAvatarColors: Equatable {
    /// The disc behind the small avatars. It is all there is of the avatar while a group has
    /// no participant to show and no title to take initials from, so it is never clear.
    let disc: Color
    /// The ring around each small avatar.
    let ring: Color
}

extension GroupAvatarColors {
    /// The avatar as it was before these were a value: every avatar of the iOS list, and every
    /// row of the Mac sidebar that is not on the accent color. `ConversationRowMetricsTests`
    /// pins both fields.
    static let standard = GroupAvatarColors(
        disc: .systemGray6,
        ring: .systemBackground
    )

    /// On the accent color, where the row draws its text and marks in white
    /// (`ConversationRowPalette.onSelectionFill`): white rings on a disc a shade lighter than
    /// the fill, the same in a light window and a dark one. The opacity is a first value, not
    /// one measured against Messages.
    static let onSelectionFill = GroupAvatarColors(
        disc: .white.opacity(0.25),
        ring: .white
    )
}
