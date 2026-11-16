import Foundation

/// Whether a dismissal of the chat's sheet clears the chat's destination state
/// (`ChatView.dismissActiveDestination`).
///
/// The chat has one sheet, and what it shows is chosen from several pieces of state
/// (`ChatView.activeDestination`). One destination can replace another: Participants' Create
/// New Contact hides Participants and sets the contact. On iOS the outgoing sheet is then
/// dismissed and its `onDismiss` runs with the incoming destination already in that state, so
/// a dismissal that cleared everything would close the sheet that is taking over. The rule
/// tells the two apart by the destination the chat recorded as on screen
/// (`ChatView.presentedSheetDestination`): a dismissal clears only where no destination is
/// waiting, or the one waiting is the one on screen.
///
/// So the rule is only as good as that record. Where the record is behind, the dismissal of
/// the sheet that is up reads as a replacement's and clears nothing, and nothing then closes
/// the sheet: on the Mac, New Contact took over Participants' window with nothing told to the
/// chat, and neither of its buttons closed it (build 562, 2026-11-15). The record is kept by
/// `appSheet(item:)`'s `onItemShown`, which hears of that hand-over (`View.onSheetItemShown`).
enum ChatSheetDismissalPolicy {
    /// - Parameters:
    ///   - pendingDestinationID: The destination the chat's state asks for now, nil for none.
    ///   - dismissedDestinationID: The destination recorded as on screen when the dismissal
    ///     came, nil where no sheet's content had been shown.
    /// - Returns: False where another destination is waiting: the dismissal is the outgoing
    ///   sheet's, and the incoming destination's state is left as it is.
    static func clearsDestinations(
        pendingDestinationID: String?,
        dismissedDestinationID: String?
    ) -> Bool {
        guard let pendingDestinationID else { return true }
        return pendingDestinationID == dismissedDestinationID
    }
}
