import Foundation

/// What a seeded store of one shape contains, worked out before anything is
/// inserted: which conversation each message belongs to, who wrote it and
/// which labels it carries. It reads no clock and no random source, so two
/// stores of one shape are the same store, and a test can ask the plan what a
/// store holds without counting rows.
struct ScaleStorePlan: Sendable {
    /// What the seeder writes for one message.
    struct MessageFacts: Equatable, Sendable {
        let conversationIndex: Int
        /// The message's position among its conversation's messages, oldest first.
        let ordinalInConversation: Int
        let date: Date
        let isFromMe: Bool
        let isInInbox: Bool
        let isUnread: Bool
        let isImportant: Bool
        /// An index into `ScaleStorePlan.categoryLabelIDs`; nil for sent mail.
        let categoryIndex: Int?
        /// The other person on the message: its sender, or the recipient of
        /// sent mail. An index into the store's persons; 0 is the user.
        let counterpartPersonIndex: Int
        let ccPersonIndex: Int?

        /// The label rows the message is joined to.
        var labelIDs: [String] {
            var ids: [String] = []
            if isFromMe { ids.append("SENT") }
            if isInInbox { ids.append("INBOX") }
            if isUnread { ids.append("UNREAD") }
            if isImportant { ids.append("IMPORTANT") }
            if let categoryIndex { ids.append(ScaleStorePlan.categoryLabelIDs[categoryIndex]) }
            return ids
        }

        var participantCount: Int { ccPersonIndex == nil ? 2 : 3 }
    }

    static let selfEmail = "me@example.com"
    /// The newest message's date. Fixed, so a store does not depend on the day
    /// it was seeded.
    static let referenceDate = Date(timeIntervalSince1970: 1_790_000_000)
    /// The span the messages are spread over, oldest to newest: three years.
    static let mailboxAge: TimeInterval = 3 * 365 * 86_400
    static let categoryLabelIDs = [
        "CATEGORY_PERSONAL", "CATEGORY_UPDATES", "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"
    ]
    static let labelIDs = ["INBOX", "UNREAD", "SENT", "IMPORTANT"] + categoryLabelIDs
    /// The largest conversation is a mailing list, and this many people post to it.
    static let listSenderCount = 25

    let shape: ScaleStoreShape
    /// Message count per conversation. Index 0 is the largest conversation,
    /// the next `shape.largeConversationCount` are the busy ones.
    let conversationMessageCounts: [Int]
    private let conversationOfMessage: [Int32]
    private let ordinalOfMessage: [Int32]

    init(shape: ScaleStoreShape) {
        let busyCount = 1 + shape.largeConversationCount
        let busyMessages = shape.largestConversationMessageCount
            + shape.largeConversationCount * shape.largeConversationMessageCount
        let ordinaryCount = shape.conversationCount - busyCount
        let ordinaryMessages = shape.messageCount - busyMessages
        precondition(shape.personCount > Self.listSenderCount, "A store needs more persons than list senders")
        precondition(ordinaryCount > 0 && ordinaryMessages >= ordinaryCount, "Every conversation needs a message")

        var counts = [shape.largestConversationMessageCount]
        counts += Array(repeating: shape.largeConversationMessageCount, count: shape.largeConversationCount)
        let base = ordinaryMessages / ordinaryCount
        let remainder = ordinaryMessages % ordinaryCount
        counts += (0..<ordinaryCount).map { base + ($0 < remainder ? 1 : 0) }

        // Mail arrives interleaved, so the messages of one conversation are
        // spread through the store and not stored side by side.
        var schedule: [Int32] = []
        schedule.reserveCapacity(shape.messageCount)
        for (conversationIndex, count) in counts.enumerated() {
            schedule += Array(repeating: Int32(conversationIndex), count: count)
        }
        var generator = SplitMix64(state: 0x5CA1_E000)
        for index in stride(from: schedule.count - 1, to: 0, by: -1) {
            schedule.swapAt(index, Int(generator.next() % UInt64(index + 1)))
        }

        var seen = [Int32](repeating: 0, count: counts.count)
        var ordinals: [Int32] = []
        ordinals.reserveCapacity(schedule.count)
        for conversationIndex in schedule {
            ordinals.append(seen[Int(conversationIndex)])
            seen[Int(conversationIndex)] += 1
        }

        self.shape = shape
        self.conversationMessageCounts = counts
        self.conversationOfMessage = schedule
        self.ordinalOfMessage = ordinals
    }

    var busyConversationCount: Int { 1 + shape.largeConversationCount }

    func isListConversation(_ conversationIndex: Int) -> Bool {
        conversationIndex == 0
    }

    /// The persons in a conversation beside the user.
    func counterpartPersonIndexes(forConversation conversationIndex: Int) -> [Int] {
        let others = shape.personCount - 1
        if isListConversation(conversationIndex) {
            return Array(1...Self.listSenderCount)
        }
        let first = 1 + (conversationIndex &* 7_919) % others
        // One conversation in seven is a group of three other people.
        guard conversationIndex % 7 == 3 else { return [first] }
        return [first, 1 + (first + 1) % others, 1 + (first + 2) % others]
    }

    /// Whether an ordinary conversation is in the inbox. An archived one has
    /// no INBOX mail at all, which is what an archived chat looks like. The
    /// busy conversations decide per message.
    private func isInboxConversation(_ conversationIndex: Int) -> Bool {
        roll(conversationIndex, salt: 0xC0) < inboxPerMilleOfReceived
    }

    private var inboxPerMilleOfReceived: Int {
        shape.inboxPerMille * 1_000 / (1_000 - shape.sentPerMille)
    }

    func facts(forMessage index: Int) -> MessageFacts {
        let conversationIndex = Int(conversationOfMessage[index])
        let ordinal = Int(ordinalOfMessage[index])
        let spacing = Self.mailboxAge / Double(max(shape.messageCount - 1, 1))
        let date = Self.referenceDate.addingTimeInterval(-spacing * Double(shape.messageCount - 1 - index))

        let isFromMe = roll(index, salt: 0x01) < shape.sentPerMille
        let isInInbox: Bool
        if isFromMe {
            isInInbox = false
        } else if conversationIndex < busyConversationCount {
            isInInbox = roll(index, salt: 0x02) < inboxPerMilleOfReceived
        } else {
            isInInbox = isInboxConversation(conversationIndex)
        }
        let isUnread = isInInbox && roll(index, salt: 0x03) < shape.unreadPerMille * 1_000 / shape.inboxPerMille
        let isImportant = !isFromMe
            && roll(index, salt: 0x04) < shape.importantPerMille * 1_000 / (1_000 - shape.sentPerMille)
        let counterparts = counterpartPersonIndexes(forConversation: conversationIndex)
        let hasCc = roll(index, salt: 0x05) < shape.ccPerMille

        return MessageFacts(
            conversationIndex: conversationIndex,
            ordinalInConversation: ordinal,
            date: date,
            isFromMe: isFromMe,
            isInInbox: isInInbox,
            isUnread: isUnread,
            isImportant: isImportant,
            categoryIndex: isFromMe ? nil : roll(index, salt: 0x06) % Self.categoryLabelIDs.count,
            counterpartPersonIndex: counterparts[ordinal % counterparts.count],
            ccPersonIndex: hasCc ? 1 + roll(index, salt: 0x07, bound: shape.personCount - 1) : nil
        )
    }

    /// A number in `0..<bound` that depends only on `index` and `salt`.
    private func roll(_ index: Int, salt: UInt64, bound: Int = 1_000) -> Int {
        var generator = SplitMix64(state: UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15 ^ (salt << 56))
        return Int(generator.next() % UInt64(bound))
    }

    private struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }
}
