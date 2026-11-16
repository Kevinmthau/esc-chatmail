import Foundation

/// Who the sheet a chat's header opens lists (`ParticipantsListView`), and what it is called.
///
/// Every conversation's header opens it. A mailing list's used to open nothing, because the
/// sheet listed the conversation's participant rows, and a list's rows are the people on the
/// first message filed there: shown as the list's membership they named whoever posted first
/// and nobody since. But a header that did nothing on a tap read as broken beside every other
/// chat's, and left no way to add a list's sender to Contacts. So a list's sheet lists the
/// people who have written to it, read from its messages, under a title that says so.
enum ParticipantsListPolicy {
    enum Listing: Equatable {
        /// The conversation's participant rows: the people the chat is with.
        case participants
        /// The senders of the conversation's received messages.
        case senders
    }

    static func listing(conversationType: ConversationType) -> Listing {
        switch conversationType {
        case .oneToOne, .group:
            return .participants
        case .list:
            return .senders
        }
    }

    /// The rows the sheet draws when it is handed the senders resolved so far, while the rest
    /// are still being resolved (`ParticipantLoader.resolveSenders`'s `onProgress`): those
    /// senders, then the rows it already shows that the resolve has not reached.
    ///
    /// A sheet filling for the first time shows nothing the resolve has not reached, so it
    /// draws the senders resolved so far and grows. One that already has rows is resolving
    /// again after a change in Contacts, and its rows are replaced from the top as they are
    /// resolved while the rest stay: drawing only the senders resolved so far would cut a
    /// list of hundreds back to its first batch and grow it again.
    ///
    /// The rule this replaces drew the senders resolved so far only where they were more
    /// rows than the sheet showed. A sheet resolving again then kept every row of the
    /// earlier resolve until the new one had passed it, a contact just added still shown as
    /// none, and where the earlier resolve had itself been cut short those rows were its
    /// first batches, on screen for as many batches again.
    ///
    /// Senders are resolved in ascending order of normalized address
    /// (`ConversationParticipantExtractor.nonMeSenderEmails`), so a shown row has been
    /// reached where its address is not after the last resolved sender's. A row after that
    /// is also left out where a resolved sender has its `id`: a contact that has gained an
    /// earlier address is listed under that one now, and two rows of one `id` are drawn as
    /// one or as neither.
    ///
    /// What the last batch leaves is not this function's: the sheet then draws the result,
    /// which is everyone.
    static func sendersToDraw<Row>(
        resolvedSoFar: [Row],
        shown: [Row],
        id: (Row) -> String,
        normalizedAddress: (Row) -> String
    ) -> [Row] {
        guard let lastResolved = resolvedSoFar.last else { return shown }

        let lastResolvedAddress = normalizedAddress(lastResolved)
        let resolvedIDs = Set(resolvedSoFar.map(id))
        let notYetReached = shown.filter { row in
            normalizedAddress(row) > lastResolvedAddress && !resolvedIDs.contains(id(row))
        }
        return resolvedSoFar + notYetReached
    }

    /// The sheet's title. "Participants" would claim a list's senders are everyone in it.
    static func title(for listing: Listing) -> String {
        switch listing {
        case .participants:
            return "Participants"
        case .senders:
            return "Senders"
        }
    }
}
