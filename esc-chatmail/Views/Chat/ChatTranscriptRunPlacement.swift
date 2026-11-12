import Foundation

/// Where a row sits in its run of bubbles, and what it draws above itself: decided by the
/// transcript from the rows on either side (`ChatTranscriptRunPolicy.placement`) and handed to
/// the bubble, so everything here is known when the row mounts.
struct ChatTranscriptRunPlacement: Equatable {
    /// The first row of a run: it carries the sender's name in a group, where the style shows
    /// the name once a run.
    var startsRun: Bool
    /// The last row of a run: it carries the avatar in a group, and the bubble's tail.
    var endsRun: Bool
    /// The date of the time line drawn above the row, or nil for none.
    var separatorDate: Date?
    /// Space above the row, inside it, on top of the stack's own spacing.
    var topPadding: CGFloat

    /// A row on its own, with nothing above it: the bubble's default, and what the styles
    /// without runs or time lines give every row.
    static let alone = ChatTranscriptRunPlacement(
        startsRun: true,
        endsRun: true,
        separatorDate: nil,
        topPadding: 0
    )
}
