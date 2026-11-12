import SwiftUI

/// The sizes, spacing and fonts of a conversation row (`ConversationRowView`), as a value.
///
/// The iOS list and the Mac sidebar draw one row view (`docs/mac-imessage-ui-plan.md`, PR 2).
/// What differs between them is in here, so the row's body holds no platform check, and a
/// change to one platform's numbers cannot reach the other's.
///
/// - `iOS` is the row as it was before these were a value. `ConversationRowMetricsTests` pins
///   every field, so the iPhone's row does not move when the Mac's is tuned.
/// - `mac` is a first reading of Messages on macOS 26, from a screenshot. It has not been
///   measured side by side with Messages, the way the iOS numbers were, and it has not been
///   seen in the app.
struct ConversationRowMetrics: Equatable {
    let unreadIndicatorDiameter: CGFloat
    /// The avatar's diameter. `AvatarStackView` draws at whatever diameter it is given.
    let avatarDiameter: CGFloat
    let titleFont: Font
    /// The timestamp's font and the preview's. One font in Messages, on both platforms.
    let secondaryTextFont: Font
    /// Above the title. With `textColumnBottomPadding` it sets the row's height: the text
    /// column's padding does, not a fixed frame, so the row grows with its text.
    let textColumnTopPadding: CGFloat
    let textColumnBottomPadding: CGFloat
    let titleToPreviewSpacing: CGFloat
    /// From the row's leading edge to the unread indicator. The row's own padding: a list that
    /// gives its rows insets adds them outside this (`mac`).
    let rowLeadingPadding: CGFloat
    let unreadIndicatorToAvatarSpacing: CGFloat
    let avatarToTextSpacing: CGFloat
    let rowTrailingPadding: CGFloat
    /// Between the timestamp and the chevron. Unused where `showsChevron` is false.
    let timestampToChevronSpacing: CGFloat
    /// The disclosure chevron after the timestamp. A row that pushes a screen has one; a row
    /// that is selected in place does not.
    let showsChevron: Bool
}

extension ConversationRowMetrics {
    /// The iPhone's row: spacing matched to Messages on iOS 26, measured side by side at the
    /// same text size.
    ///
    /// The bottom padding is deeper than the top because the title's line box holds more room
    /// above its ascenders than the last preview line holds below its descenders; 11 over 14.5
    /// spaces the visible text evenly between separators, as in Messages. The old fixed 88pt
    /// row left its text almost no room at larger text sizes.
    static let iOS = ConversationRowMetrics(
        unreadIndicatorDiameter: 10,
        avatarDiameter: 44,
        titleFont: .headline,
        secondaryTextFont: .subheadline,
        textColumnTopPadding: 11,
        textColumnBottomPadding: 14.5,
        titleToPreviewSpacing: 4,
        rowLeadingPadding: 8,
        unreadIndicatorToAvatarSpacing: 9,
        avatarToTextSpacing: 12,
        rowTrailingPadding: 20,
        timestampToChevronSpacing: 12,
        showsChevron: true
    )

    /// The Mac sidebar's row. On macOS `.headline` is 13 points bold and `.body` 13 points
    /// regular, the sizes the plan read off Messages.
    ///
    /// The sidebar's `.inset` list gives every row 16 points on each side and about 4 above and
    /// below (measured off screen on macOS 27.2; `docs/mac-imessage-ui-plan.md`, "Spike results"
    /// and "PR 2 as built"), so the paddings here are what the row adds inside those. The row
    /// comes to 73.5 points. The selection's fill starts 10
    /// points in from the list's edge: the unread indicator sits 6 points inside it, and the
    /// timestamp ends 10 points inside it.
    static let mac = ConversationRowMetrics(
        unreadIndicatorDiameter: 8,
        avatarDiameter: 40,
        titleFont: .headline,
        secondaryTextFont: .body,
        textColumnTopPadding: 7,
        textColumnBottomPadding: 9,
        titleToPreviewSpacing: 2,
        rowLeadingPadding: 0,
        unreadIndicatorToAvatarSpacing: 6,
        avatarToTextSpacing: 10,
        rowTrailingPadding: 4,
        timestampToChevronSpacing: 0,
        showsChevron: false
    )
}
