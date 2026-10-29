import Foundation

/// When `AttachmentGridView` clears its Quick Look state.
///
/// Each tap stores a new `QuickLookPresentation`, and the `.task(id:)` keyed on its
/// id cancels the run for the one it replaced. A replaced run must not clear the
/// state: `TopPresentableViewController.present` also returns `false` when
/// cancelled, so treating that as "no presenter" logged a bogus error and wiped
/// the newer presentation, cancelling its run before it could present. A
/// dismissal clears only the presentation it closed for the same reason.
enum QuickLookPresentationPolicy {
    /// Whether a finished present attempt for `attempted` gives up and clears the
    /// state: only a run that was not cancelled, found no presenter, and still
    /// owns the state.
    static func shouldClearAfterPresentAttempt(
        _ attempted: QuickLookPresentation.ID,
        didPresent: Bool,
        wasCancelled: Bool,
        current: QuickLookPresentation.ID?
    ) -> Bool {
        !didPresent && !wasCancelled && current == attempted
    }

    /// Whether Quick Look dismissing `dismissed` clears the state.
    static func shouldClearOnDismiss(
        of dismissed: QuickLookPresentation.ID,
        current: QuickLookPresentation.ID?
    ) -> Bool {
        current == dismissed
    }
}
