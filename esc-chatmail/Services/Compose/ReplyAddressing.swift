import Foundation

/// Who a reply goes to, and whether that is who the conversation it is typed
/// in names (`ReplyMetadataBuilder.replyAddressing`).
struct ReplyAddressing: Equatable, Sendable {
    /// The reply's recipients, the user's own addresses already removed.
    let recipients: [String]

    /// The recipients are the people on the message being replied to and not
    /// the conversation's participant rows, because the rows would reach
    /// someone who was not on that message or miss the person who wrote it
    /// (`ReplyLinkedAddressPolicy.rowsCanAnswer`). The send logs it.
    let overrulesConversationRows: Bool

    /// The recipients are not the people a participant conversation's rows
    /// name (`ReplyLinkedAddressPolicy.recipientsAreConversationPeople`),
    /// whichever rule addressed the reply.
    ///
    /// The chat's title is made from the rows, so this is where a reply goes
    /// to people the title does not name, or not to all it names. Two rules
    /// get there: a reply that overrules the rows (`overrulesConversationRows`),
    /// and one that follows the message's Reply-To header to an address the
    /// rows do not hold. It is read from the outcome and not set by either
    /// rule, so a rule added later cannot address a reply elsewhere unseen.
    /// The composer says so above its field (`ReplyIndicatorPolicy`).
    ///
    /// Always false for a List-Id conversation, whose title is the list and
    /// whose replies are addressed from the post, and for a conversation with
    /// no row but the user's own.
    let differsFromConversationPeople: Bool

    /// Those of `recipients` who are none of the people the conversation's
    /// rows name (`ReplyLinkedAddressPolicy.recipientsOutsideConversation`),
    /// in the order `recipients` has them. Empty where nothing is announced,
    /// and where the reply only leaves out someone the rows name.
    let recipientsOutsideConversation: [String]

    init(
        recipients: [String],
        overrulesConversationRows: Bool,
        differsFromConversationPeople: Bool,
        recipientsOutsideConversation: [String] = []
    ) {
        self.recipients = recipients
        self.overrulesConversationRows = overrulesConversationRows
        self.differsFromConversationPeople = differsFromConversationPeople
        self.recipientsOutsideConversation = recipientsOutsideConversation
    }

    /// The recipients to name in the composer: nil unless they are other
    /// people than the conversation's own.
    ///
    /// Every recipient, those outside the conversation first. This is the
    /// order they are named in and not the order the reply is addressed in,
    /// which is `recipients`. The row that names them counts what it has no
    /// room for (`ReplyIndicatorPolicy.quoteRowAnnouncedRecipientLimit`), and
    /// the order of `recipients` is partly the sender's (a Reply-To header's
    /// addresses come first, as written): left in it, a header that named the
    /// chat's own people ahead of a third address had the row name the people
    /// the title already names and count the one it exists to show.
    var recipientsToAnnounce: [String]? {
        guard differsFromConversationPeople, !recipients.isEmpty else { return nil }
        let outside = recipientsOutsideConversation
        return outside + recipients.filter { !outside.contains($0) }
    }
}
