import Foundation

/// When `AttachmentGridView` clears its Quick Look state.
///
/// Each tap stores a new `QuickLookPresentation`, and the `.task(id:)` keyed on its
/// id cancels the run for the one it replaced. A replaced run must not clear the
/// state: treating its cancellation as "no presenter" logged a bogus error and
/// wiped the newer presentation, cancelling its run before it could present. A
/// dismissal clears only the presentation it closed for the same reason.
///
/// A run cancelled while it still owns the state (the view disappeared mid-retry)
/// does clear it. Kept, the state would restart the `.task` when the view
/// reappears and open Quick Look unprompted, and the snapshot would keep holding
/// its `Attachment` objects.
enum QuickLookPresentationPolicy {
    /// Whether a finished present attempt for `attempted` clears the state: any
    /// attempt that did not present, while it still owns the state.
    static func shouldClearAfterPresentAttempt(
        _ attempted: QuickLookPresentation.ID,
        outcome: TopPresentableViewController.Outcome,
        current: QuickLookPresentation.ID?
    ) -> Bool {
        outcome != .presented && current == attempted
    }

    /// Whether Quick Look dismissing `dismissed` clears the state.
    static func shouldClearOnDismiss(
        of dismissed: QuickLookPresentation.ID,
        current: QuickLookPresentation.ID?
    ) -> Bool {
        current == dismissed
    }
}
