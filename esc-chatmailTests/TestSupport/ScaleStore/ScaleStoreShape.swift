import Foundation

/// The size and proportions of a seeded mailbox store.
///
/// The reference scales are the ones in `docs/scalability-review.md`
/// ("Reference scales" and "Capacity model"). Two proportions there are
/// assumptions of that review and not measurements of a real mailbox: about
/// 81% of messages carry INBOX and about 22% are unread. Every hub-fault and
/// unread-snapshot number scales with them, so they are fields here and not
/// constants in the seeder.
struct ScaleStoreShape: Equatable, Sendable {
    var messageCount: Int
    var conversationCount: Int
    /// Includes the user's own Person.
    var personCount: Int
    /// The one conversation that never stops growing: a list or a
    /// notification sender.
    var largestConversationMessageCount: Int
    /// Busy conversations after the largest one, and the size of each.
    var largeConversationCount: Int
    var largeConversationMessageCount: Int
    /// Messages sent by the user, per thousand. They carry SENT and no INBOX.
    var sentPerMille: Int
    /// Messages that carry INBOX, per thousand of all messages.
    var inboxPerMille: Int
    /// Unread messages, per thousand of all messages. All of them are in INBOX.
    var unreadPerMille: Int
    /// Messages with one Cc participant beside From and To, per thousand.
    /// With From and To on every message, 600 gives the review's 2.6
    /// participants per message.
    var ccPerMille: Int
    /// Received messages that carry IMPORTANT, per thousand of all messages.
    var importantPerMille: Int
    /// Characters of `bodyText` per message. The review's stores had 3-4 KB,
    /// which is what makes an S2 store 0.7 GB; nothing the harness asserts
    /// depends on it, so the default keeps the file small.
    var bodyTextLength: Int
    /// Messages saved per transaction while seeding.
    var seedBatchSize: Int

    /// Heavy user, a few years: 120k messages in 12k conversations.
    static let s2 = ScaleStoreShape(
        messageCount: 120_000,
        conversationCount: 12_000,
        personCount: 8_000,
        largestConversationMessageCount: 20_000,
        largeConversationCount: 5,
        largeConversationMessageCount: 2_000,
        sentPerMille: 70,
        inboxPerMille: 810,
        unreadPerMille: 220,
        ccPerMille: 600,
        importantPerMille: 280,
        bodyTextLength: 240,
        seedBatchSize: 2_000
    )

    /// Light user, about a year: 15k messages in 1.5k conversations.
    static let s1 = ScaleStoreShape(
        messageCount: 15_000,
        conversationCount: 1_500,
        personCount: 2_000,
        largestConversationMessageCount: 1_500,
        largeConversationCount: 3,
        largeConversationMessageCount: 400,
        sentPerMille: 70,
        inboxPerMille: 810,
        unreadPerMille: 220,
        ccPerMille: 600,
        importantPerMille: 280,
        bodyTextLength: 240,
        seedBatchSize: 2_000
    )

    /// The same proportions at a size the default test plan can afford, for
    /// the tests of the seeder itself. Its batches are smaller than its
    /// message count on purpose, so those tests cross a batch boundary.
    static let miniature = ScaleStoreShape(
        messageCount: 2_000,
        conversationCount: 200,
        personCount: 150,
        largestConversationMessageCount: 300,
        largeConversationCount: 2,
        largeConversationMessageCount: 100,
        sentPerMille: 70,
        inboxPerMille: 810,
        unreadPerMille: 220,
        ccPerMille: 600,
        importantPerMille: 280,
        bodyTextLength: 80,
        seedBatchSize: 700
    )
}
