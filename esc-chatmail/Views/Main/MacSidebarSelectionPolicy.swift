import Foundation

/// Decides what the Mac's chat column shows for the sidebar's selection, and what the selection
/// becomes when conversations leave it (`MacMailboxView`, `MacConversationSidebar`).
///
/// On iOS a chat is a pushed screen, and it closes by popping. On the Mac the open chat *is* the
/// selected row, so every way a chat can close is a change to this set. The rules are generic over
/// the row's identifier and compile on both platforms, so they are tested without Core Data and
/// run in the iOS suite as well as `Mac.xctestplan`.
enum MacSidebarSelectionPolicy {
    enum Detail<ID: Hashable>: Equatable {
        /// Nothing is selected. Also the launch state: nothing is selected for the user, because
        /// opening a chat marks it read.
        case placeholder
        case conversation(ID)
        /// Several rows are selected (Shift-click, Command-click): the column offers the batch
        /// actions instead of a chat.
        case multiple(count: Int)
    }

    static func detail<ID: Hashable>(for selection: Set<ID>) -> Detail<ID> {
        switch selection.count {
        case 0:
            return .placeholder
        case 1:
            // `first` of a one-element set; the fallback is unreachable.
            return selection.first.map(Detail.conversation) ?? .placeholder
        default:
            return .multiple(count: selection.count)
        }
    }

    /// The rows a list action (Delete, the context menu, a swipe) acts on: only rows the list is
    /// showing. The selection can also hold a conversation that a search or filter is hiding
    /// (`selectionAfterListChange`), and archiving a row the user cannot see would be a surprise.
    static func actionTargets<ID: Hashable>(requested: Set<ID>, visibleIDs: Set<ID>) -> Set<ID> {
        requested.intersection(visibleIDs)
    }

    /// The conversations the Mailbox menu's Mark as Read / Mark as Unread command acts on
    /// (Command-Shift-U; `MailboxMenuPolicy.readStateCommand`).
    ///
    /// - One selected conversation → that one, listed or not. It is the open chat, in front of
    ///   the user in the chat column even while a search hides its row, and the command reads
    ///   as being about it.
    /// - Several → the selected rows the list is showing, as for Delete (`actionTargets`).
    ///
    /// `visibleIDs` is walked only for several selected rows: this is asked on every update of
    /// the sidebar, where one selected row is the usual case.
    static func readStateTargets<ID: Hashable, Visible: Sequence>(
        selection: Set<ID>,
        visibleIDs: Visible
    ) -> Set<ID> where Visible.Element == ID {
        guard selection.count > 1 else { return selection }
        return Set(visibleIDs.filter(selection.contains))
    }

    /// The selection after the user archives or reports `actedOn` from the list.
    ///
    /// When that empties the selection, it moves to the row that takes the removed rows' place
    /// (the next row, else the one before), so Delete, Delete, Delete works through the list
    /// from the keyboard the way it does in every Mac list. The user asked for that row to
    /// leave, so they are looking at what replaces it; that is the difference from a conversation
    /// that leaves by itself (`selectionAfterListChange`), which selects nothing.
    ///
    /// Rows that were selected but not acted on stay selected and nothing is added: a
    /// right-click on an unselected row archives that row and leaves the open chat alone.
    static func selectionAfterListAction<ID: Hashable>(
        selection: Set<ID>,
        actedOn: Set<ID>,
        orderedVisibleIDs: [ID]
    ) -> Set<ID> {
        guard !selection.isDisjoint(with: actedOn) else { return selection }
        let remaining = selection.subtracting(actedOn)
        guard remaining.isEmpty else { return remaining }

        let actedOnIndices = orderedVisibleIDs.indices.filter { actedOn.contains(orderedVisibleIDs[$0]) }
        guard let firstIndex = actedOnIndices.first, let lastIndex = actedOnIndices.last else { return [] }
        if let next = orderedVisibleIDs[(lastIndex + 1)...].first(where: { !actedOn.contains($0) }) {
            return [next]
        }
        if let previous = orderedVisibleIDs[..<firstIndex].last(where: { !actedOn.contains($0) }) {
            return [previous]
        }
        return []
    }

    /// The selection after the open chat closes itself: its own Archive or Report Spam, or the
    /// conversation drained (`ChatView.onExit`). Nothing replaces it, as on iOS, where the chat
    /// pops back to the list.
    static func selectionAfterChatExit<ID: Hashable>(selection: Set<ID>, exited: ID) -> Set<ID> {
        selection.subtracting([exited])
    }

    /// The selection after the list's rows change.
    ///
    /// A selected conversation that is no longer listed stays selected while it can still be
    /// opened: a search or a filter hid its row, and typing in the search field must not close
    /// the chat being read. One that cannot be opened any more (archived or deleted by a sync)
    /// leaves the selection, and nothing is selected in its place: selecting a row marks it read,
    /// and the user did not choose one.
    ///
    /// `isOpenable` is asked only about selected conversations that are not listed.
    static func selectionAfterListChange<ID: Hashable>(
        selection: Set<ID>,
        visibleIDs: Set<ID>,
        isOpenable: (ID) -> Bool
    ) -> Set<ID> {
        selection.filter { visibleIDs.contains($0) || isOpenable($0) }
    }
}
