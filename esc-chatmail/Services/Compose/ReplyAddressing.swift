import Foundation

/// Who a reply goes to, and whether that is who the conversation it is typed
/// in names (`ReplyMetadataBuilder.replyAddressing`).
struct ReplyAddressing: Equatable, Sendable {
    /// The reply's recipients, the user's own addresses already removed.
    let recipients: [String]

    /// The recipients are the people on the message being replied to and not
    /// the conversation's participant rows, because the rows would reach
    /// someone who was not on that message or miss the person who wrote it
    /// (`ReplyLinkedAddressPolicy.rowsCanAnswer`).
    ///
    /// The chat's title is made from the rows, so this is the one case where
    /// a reply goes to people the title does not name. The composer says so
    /// above its field (`ReplyIndicatorPolicy`), and the send logs it.
    let overrulesConversationRows: Bool

    /// The recipients to name in the composer: nil unless they are other
    /// people than the conversation's own.
    var recipientsToAnnounce: [String]? {
        overrulesConversationRows && !recipients.isEmpty ? recipients : nil
    }
}
