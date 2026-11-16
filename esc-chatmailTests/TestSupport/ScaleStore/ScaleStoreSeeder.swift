import Foundation
import CoreData
@testable import esc_chatmail

/// Fills a store with a mailbox of a given shape through Core Data, in
/// batches, so the store is what the app would have written: the model's own
/// tables, join tables and indexes, and no hand-written SQL.
///
/// It goes into a SQLite store. An in-memory store has no SQL and no faults
/// to speak of, which is the whole reason for the harness. Use
/// `ScaleStoreTemplate` to seed once and hand each test a copy.
enum ScaleStoreSeeder {
    /// Object IDs of the rows every batch relates its messages to.
    private struct Anchors {
        let labels: [String: NSManagedObjectID]
        let persons: [NSManagedObjectID]
        let conversations: [NSManagedObjectID]
    }

    /// What a conversation's row says about its messages.
    private struct Rollup {
        var firstDate: Date?
        var lastDate: Date?
        var lastSnippet: String?
        var latestInboxDate: Date?
        var inboxUnreadCount: Int32 = 0
        var hasInbox = false
        var messageCount = 0
    }

    static func conversationID(at index: Int) -> UUID {
        // A fixed prefix and the index, so a conversation's UUID is known
        // from the plan alone.
        UUID(uuidString: String(format: "5CA1E000-0000-4000-8000-%012X", index))!
    }

    static func personEmail(at index: Int) -> String {
        index == 0 ? ScaleStorePlan.selfEmail : "person\(index)@example.com"
    }

    static func messageID(at index: Int) -> String {
        String(format: "5ca1e%011x", index)
    }

    /// Seeds `shape` through `context`, which must be a private-queue context
    /// of a SQLite store, and saves. The context is reset after every batch.
    @discardableResult
    static func seed(_ shape: ScaleStoreShape, in context: NSManagedObjectContext) throws -> ScaleStoreManifest {
        let plan = ScaleStorePlan(shape: shape)
        let anchors = try context.performAndWait {
            try insertAnchors(for: plan, in: context)
        }

        var rollups = [Rollup](repeating: Rollup(), count: shape.conversationCount)
        var inboxMessageCount = 0
        var unreadMessageCount = 0
        var messageParticipantCount = 0
        var labelMembershipCount = 0

        for batchStart in stride(from: 0, to: shape.messageCount, by: shape.seedBatchSize) {
            let range = batchStart..<min(batchStart + shape.seedBatchSize, shape.messageCount)
            let batch = try context.performAndWait {
                try insertMessages(range, of: plan, anchors: anchors, in: context)
            }
            for facts in batch {
                var rollup = rollups[facts.conversationIndex]
                rollup.firstDate = rollup.firstDate ?? facts.date
                rollup.lastDate = facts.date
                rollup.lastSnippet = snippet(forMessageAt: facts)
                rollup.messageCount += 1
                if facts.isInInbox {
                    rollup.hasInbox = true
                    rollup.latestInboxDate = facts.date
                    inboxMessageCount += 1
                }
                if facts.isUnread {
                    rollup.inboxUnreadCount += 1
                    unreadMessageCount += 1
                }
                rollups[facts.conversationIndex] = rollup
                messageParticipantCount += facts.participantCount
                labelMembershipCount += facts.labelIDs.count
            }
        }

        let finishedRollups = rollups
        for batchStart in stride(from: 0, to: shape.conversationCount, by: shape.seedBatchSize) {
            let range = batchStart..<min(batchStart + shape.seedBatchSize, shape.conversationCount)
            try context.performAndWait {
                try writeRollups(finishedRollups, for: range, anchors: anchors, in: context)
            }
        }

        let ordinaryIndex = finishedRollups.indices.dropFirst(plan.busyConversationCount).first { index in
            finishedRollups[index].hasInbox && finishedRollups[index].inboxUnreadCount > 0
        }
        let ordinaryInboxMessageIndex = ordinaryIndex.flatMap { ordinaryIndex in
            (0..<shape.messageCount).first { index in
                let facts = plan.facts(forMessage: index)
                return facts.conversationIndex == ordinaryIndex && facts.isInInbox
            }
        }
        guard let ordinaryIndex, let ordinaryInboxMessageIndex else {
            throw CocoaError(.validationMissingMandatoryProperty, userInfo: [
                NSLocalizedDescriptionKey: "The shape has no ordinary conversation with unread inbox mail"
            ])
        }

        return ScaleStoreManifest(
            shape: shape,
            selfEmail: ScaleStorePlan.selfEmail,
            largestConversationID: conversationID(at: 0),
            largestConversationMessageCount: finishedRollups[0].messageCount,
            ordinaryConversationID: conversationID(at: ordinaryIndex),
            ordinaryConversationMessageCount: finishedRollups[ordinaryIndex].messageCount,
            ordinaryConversationUnreadCount: Int(finishedRollups[ordinaryIndex].inboxUnreadCount),
            ordinaryConversationInboxMessageID: messageID(at: ordinaryInboxMessageIndex),
            messageCount: shape.messageCount,
            inboxMessageCount: inboxMessageCount,
            unreadMessageCount: unreadMessageCount,
            messageParticipantCount: messageParticipantCount,
            labelMembershipCount: labelMembershipCount,
            archivedConversationCount: finishedRollups.filter { !$0.hasInbox }.count
        )
    }

    private static func snippet(forMessageAt facts: ScaleStorePlan.MessageFacts) -> String {
        "Message \(facts.ordinalInConversation + 1) of conversation \(facts.conversationIndex)"
    }

    private static func insertAnchors(
        for plan: ScaleStorePlan,
        in context: NSManagedObjectContext
    ) throws -> Anchors {
        let shape = plan.shape

        let account = context.insertTestObject(Account.self)
        account.id = "scale-account"
        account.email = ScaleStorePlan.selfEmail
        account.historyId = "1"

        let labels = ScaleStorePlan.labelIDs.map { labelID in
            let label = context.insertTestObject(Label.self)
            label.id = labelID
            label.name = labelID
            return label
        }

        let persons = (0..<shape.personCount).map { index in
            let person = context.insertTestObject(Person.self)
            person.id = UUID(uuidString: String(format: "5CA1E001-0000-4000-8000-%012X", index))!
            person.email = personEmail(at: index)
            person.displayName = index == 0 ? "Me" : "Person \(index)"
            return person
        }

        let conversations = (0..<shape.conversationCount).map { index in
            let conversation = context.insertTestObject(Conversation.self)
            let counterparts = plan.counterpartPersonIndexes(forConversation: index)
            conversation.id = conversationID(at: index)
            conversation.keyHash = "scale-key-\(index)"
            if plan.isListConversation(index) {
                conversation.type = ConversationType.list.rawValue
                conversation.listId = "announce.lists.example.com"
                conversation.participantHash = "l|scale-\(index)"
                conversation.displayName = "Announcements"
            } else {
                conversation.type = (counterparts.count > 1 ? ConversationType.group : .oneToOne).rawValue
                conversation.participantHash = "p|scale-\(index)"
                conversation.displayName = counterparts.map { "Person \($0)" }.joined(separator: ", ")
            }

            let me = context.insertTestObject(ConversationParticipant.self)
            me.id = UUID()
            me.role = ParticipantRole.me.rawValue
            me.person = persons[0]
            me.conversation = conversation
            for personIndex in counterparts {
                let participant = context.insertTestObject(ConversationParticipant.self)
                participant.id = UUID()
                participant.role = ParticipantRole.normal.rawValue
                participant.person = persons[personIndex]
                participant.conversation = conversation
            }
            return conversation
        }

        try context.obtainPermanentIDs(for: labels + persons + conversations)
        try context.save()
        let anchors = Anchors(
            labels: Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0.objectID) }),
            persons: persons.map(\.objectID),
            conversations: conversations.map(\.objectID)
        )
        context.reset()
        return anchors
    }

    private static func insertMessages(
        _ range: Range<Int>,
        of plan: ScaleStorePlan,
        anchors: Anchors,
        in context: NSManagedObjectContext
    ) throws -> [ScaleStorePlan.MessageFacts] {
        let bodyText = String(repeating: "Lorem ipsum dolor sit amet. ", count: plan.shape.bodyTextLength / 28 + 1)
            .prefix(plan.shape.bodyTextLength)
        let labels = anchors.labels.mapValues { context.object(with: $0) as? Label }
        func person(_ index: Int) -> Person? {
            context.object(with: anchors.persons[index]) as? Person
        }
        func participant(_ kind: ParticipantKind, _ personIndex: Int, of message: Message) {
            let participant = context.insertTestObject(MessageParticipant.self)
            participant.id = UUID()
            participant.kind = kind.rawValue
            participant.person = person(personIndex)
            participant.message = message
        }

        var batch: [ScaleStorePlan.MessageFacts] = []
        batch.reserveCapacity(range.count)
        for index in range {
            let facts = plan.facts(forMessage: index)
            let isList = plan.isListConversation(facts.conversationIndex)
            let senderIndex = facts.isFromMe ? 0 : facts.counterpartPersonIndex
            let recipientIndex = facts.isFromMe ? facts.counterpartPersonIndex : 0

            let message = context.insertTestObject(Message.self)
            message.id = messageID(at: index)
            // A thread is a run of four messages of one conversation.
            message.gmThreadId = "scale-thread-\(facts.conversationIndex)-\(facts.ordinalInConversation / 4)"
            message.messageId = "<scale-\(index)@example.com>"
            message.internalDate = facts.date
            message.subject = "Subject \(facts.ordinalInConversation / 4)"
            message.snippet = snippet(forMessageAt: facts)
            message.cleanedSnippet = message.snippet
            message.chatPreviewText = message.snippet
            message.bodyText = String(bodyText)
            message.senderEmail = personEmail(at: senderIndex)
            message.senderName = senderIndex == 0 ? "Me" : "Person \(senderIndex)"
            message.isFromMe = facts.isFromMe
            message.isUnread = facts.isUnread
            message.isNewsletter = isList
            message.listId = isList ? "announce.lists.example.com" : nil
            message.conversation = context.object(with: anchors.conversations[facts.conversationIndex]) as? Conversation
            message.labels = Set(facts.labelIDs.compactMap { labels[$0] ?? nil })

            participant(.from, senderIndex, of: message)
            participant(.to, recipientIndex, of: message)
            if let ccPersonIndex = facts.ccPersonIndex {
                participant(.cc, ccPersonIndex, of: message)
            }
            batch.append(facts)
        }

        try context.save()
        context.reset()
        return batch
    }

    private static func writeRollups(
        _ rollups: [Rollup],
        for range: Range<Int>,
        anchors: Anchors,
        in context: NSManagedObjectContext
    ) throws {
        let request = NSFetchRequest<Conversation>(entityName: "Conversation")
        request.predicate = NSPredicate(format: "SELF IN %@", Array(anchors.conversations[range]))
        let conversations = try context.fetch(request)
        let indexByObjectID = Dictionary(
            uniqueKeysWithValues: range.map { (anchors.conversations[$0], $0) }
        )
        for conversation in conversations {
            guard let index = indexByObjectID[conversation.objectID] else { continue }
            let rollup = rollups[index]
            conversation.createdAt = rollup.firstDate
            conversation.lastMessageDate = rollup.lastDate
            conversation.snippet = rollup.lastSnippet
            conversation.hasInbox = rollup.hasInbox
            conversation.latestInboxDate = rollup.latestInboxDate
            conversation.inboxUnreadCount = rollup.inboxUnreadCount
            conversation.archivedAt = rollup.hasInbox ? nil : rollup.lastDate
        }
        try context.save()
        context.reset()
    }
}
