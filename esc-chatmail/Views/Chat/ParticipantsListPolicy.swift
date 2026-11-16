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
