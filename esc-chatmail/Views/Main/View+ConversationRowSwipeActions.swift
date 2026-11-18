import SwiftUI
import CoreData

/// A conversation row's trailing swipe and the question its Report Spam asks, for the iPhone's
/// list (`ConversationListView`) and the Mac's sidebar (`MacConversationSidebar`). Both attach
/// these, so the two swipes are one definition, pinned by
/// `ConversationListSwipeActionsSourceTests` because no test can perform a swipe.
extension View {
    /// Archive, then Report Spam, on the row's trailing edge.
    ///
    /// The order is the behavior. SwiftUI performs a full swipe with the first button, the one
    /// drawn at the row's edge, so a full swipe archives and Report Spam is reached only by a
    /// partial swipe.
    ///
    /// Report Spam only asks (`onReportSpam` raises `conversationSpamConfirmation`): it sits
    /// beside Archive, and nothing in the app takes it back (there is no Not Spam), so a tap
    /// that missed Archive by a few points would otherwise report the conversation for good.
    /// For the same reason it has no destructive role, unlike Archive: a destructive swipe
    /// button stands for the row's removal, and a list may animate the row away as the button
    /// is tapped, before the question is answered (reported of SwiftUI's lists; not measured
    /// here). The orange tint is what marks it.
    ///
    /// - Parameter isEnabled: False empties the swipe, which then offers nothing (the iPhone
    ///   list's Select mode). Both buttons are inside the one condition: a Report Spam left
    ///   outside it would be the first button while selecting, and a full swipe would perform it.
    func conversationRowTrailingSwipeActions(
        isEnabled: Bool,
        onArchive: @escaping @MainActor () -> Void,
        onReportSpam: @escaping @MainActor () -> Void
    ) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if isEnabled {
                Button(role: .destructive) {
                    onArchive()
                } label: {
                    SwiftUI.Label("Archive", systemImage: "archivebox")
                }
                .tint(.blue)
                Button {
                    onReportSpam()
                } label: {
                    SwiftUI.Label("Report Spam", systemImage: "exclamationmark.triangle")
                }
                .tint(.orange)
            }
        }
    }

    /// Asks before a row's swipe reports its conversation as spam. `conversationID` names the
    /// conversation waiting for an answer, nil while none is; the answer clears it.
    ///
    /// Attached to the list, not the row: a row can be drawn again under the question (a sync
    /// publish, and on the Mac the reload of the list's table that
    /// `MacSidebarListSelectionGuardView` makes), and a question kept by the row could go with it.
    ///
    /// - Parameter onConfirm: Reports the named conversation. It may be gone by then (archived
    ///   on another device, say); the list's own action decides what is left to do.
    func conversationSpamConfirmation(
        for conversationID: Binding<NSManagedObjectID?>,
        onConfirm: @escaping @MainActor (NSManagedObjectID) -> Void
    ) -> some View {
        confirmationDialog(
            "Report this conversation as spam?",
            isPresented: Binding(
                get: { conversationID.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented {
                        conversationID.wrappedValue = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: conversationID.wrappedValue
        ) { pendingConversationID in
            Button("Report Spam", role: .destructive) {
                onConfirm(pendingConversationID)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its messages move to Spam in Gmail, and the conversation leaves this list.")
        }
    }
}
