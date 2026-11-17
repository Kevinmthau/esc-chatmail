import XCTest
import CoreData
@testable import esc_chatmail

/// Runs the chat visibility predicate against a real SQLite store. The
/// in-memory store every other chat suite uses evaluates predicates in memory,
/// where `NONE labels.id IN %@` means what it says. The SQLite store compiled
/// `conversation.id == %@ AND NONE labels.id IN %@` to a label join that both
/// dropped messages with no labels and kept excluded ones that also carry an
/// allowed label (SPAM + INBOX). The just-sent (optimistic) reply has no labels
/// until its sync echo arrives, so on device the transcript could not publish
/// or anchor to it: the sent bubble appeared only when the echo landed, often
/// under the keyboard.
final class MessagePredicatesSQLiteTests: XCTestCase {
    private func makeThread(
        in context: NSManagedObjectContext
    ) -> Conversation {
        let conversation = ConversationBuilder().build(in: context)
        let inbox = LabelBuilder().withId("INBOX").build(in: context)
        let spam = LabelBuilder().withId("SPAM").build(in: context)

        MessageBuilder()
            .withId("optimistic-reply")
            .inConversation(conversation)
            .build(in: context)
        MessageBuilder()
            .withId("inbox-message")
            .inConversation(conversation)
            .build(in: context)
            .labels = [inbox]
        MessageBuilder()
            .withId("spam-message")
            .inConversation(conversation)
            .build(in: context)
            .labels = [spam, inbox]
        return conversation
    }

    /// Revert-check: restoring `NONE labels.id IN %@` in
    /// `MessagePredicates.visibleInChat(conversationId:)` fetches
    /// ["spam-message", "inbox-message"] here.
    func testVisibleInChatByConversationId_sqliteStore_keepsUnlabeledMessageAndExcludesSpam() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let context = stack.viewContext

        try context.performAndWait {
            let conversationUUID = makeThread(in: context).id
            try context.save()
            context.reset()

            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = MessagePredicates.visibleInChat(conversationId: conversationUUID)
            let ids = Set(try context.fetch(request).map(\.id))

            XCTAssertEqual(ids, ["optimistic-reply", "inbox-message"])
        }
    }

    /// Revert-check: restoring `NONE labels.id IN %@` in
    /// `MessagePredicates.visibleInChat(conversation:)` fetches
    /// ["spam-message", "inbox-message"] here (its count is also 2, which is
    /// why the fetched IDs are asserted).
    func testVisibleInChatByConversation_sqliteStore_keepsUnlabeledMessageAndExcludesSpam() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let context = stack.viewContext

        try context.performAndWait {
            let conversation = makeThread(in: context)
            try context.save()
            let conversationID = conversation.objectID
            context.reset()
            let reloadedConversation = try XCTUnwrap(
                context.existingObject(with: conversationID) as? Conversation
            )

            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = MessagePredicates.visibleInChat(conversation: reloadedConversation)

            XCTAssertEqual(Set(try context.fetch(request).map(\.id)), ["optimistic-reply", "inbox-message"])
            XCTAssertEqual(try context.count(for: request), 2)
        }
    }

    /// Revert-check: `NONE labels.id IN %@` in
    /// `MessagePredicates.visibleInChat(conversationObjectID:)` fetches
    /// ["spam-message", "inbox-message"] here, and dropping its
    /// `conversation == %@` adds "other-chat-message".
    func testVisibleInChatByConversationObjectID_sqliteStore_matchesTheOtherForms() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let context = stack.viewContext

        try context.performAndWait {
            let conversation = makeThread(in: context)
            MessageBuilder()
                .withId("other-chat-message")
                .inConversation(ConversationBuilder().build(in: context))
                .build(in: context)
            try context.save()
            let conversationID = conversation.objectID
            XCTAssertFalse(conversationID.isTemporaryID)
            context.reset()

            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = MessagePredicates.visibleInChat(conversationObjectID: conversationID)

            XCTAssertEqual(Set(try context.fetch(request).map(\.id)), ["optimistic-reply", "inbox-message"])
            XCTAssertEqual(try context.count(for: request), 2)
        }
    }

    /// The unread INBOX messages of one conversation, on a real SQLite store.
    ///
    /// Revert-check: dropping `conversation == %@` from
    /// `MessagePredicates.unreadInInbox` adds "other-chat-unread", dropping
    /// `isUnread != NO` adds "read-inbox", and dropping the label term adds
    /// "unread-not-in-inbox".
    ///
    /// HONEST SCOPE: `isUnread == YES` in place of `isUnread != NO` selects
    /// the same rows and passes this test. What that spelling costs is the
    /// query plan, which `ScaleQueryPlanTests` pins.
    func testUnreadInInbox_sqliteStore_selectsOnlyTheConversationsUnreadInboxMessages() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let context = stack.viewContext

        try context.performAndWait {
            let conversation = ConversationBuilder().build(in: context)
            let otherConversation = ConversationBuilder().build(in: context)
            let inbox = LabelBuilder().withId("INBOX").build(in: context)
            let important = LabelBuilder().withId("IMPORTANT").build(in: context)

            MessageBuilder().withId("unread-inbox").unread().inConversation(conversation)
                .build(in: context).labels = [inbox]
            MessageBuilder().withId("unread-inbox-and-important").unread().inConversation(conversation)
                .build(in: context).labels = [inbox, important]
            MessageBuilder().withId("read-inbox").read().inConversation(conversation)
                .build(in: context).labels = [inbox]
            MessageBuilder().withId("unread-not-in-inbox").unread().inConversation(conversation)
                .build(in: context).labels = [important]
            MessageBuilder().withId("other-chat-unread").unread().inConversation(otherConversation)
                .build(in: context).labels = [inbox]
            try context.save()
            let conversationID = conversation.objectID
            context.reset()

            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = MessagePredicates.unreadInInbox(conversationObjectID: conversationID)

            XCTAssertEqual(
                try context.fetch(request).map(\.id).sorted(),
                ["unread-inbox", "unread-inbox-and-important"]
            )
            XCTAssertEqual(try context.count(for: request), 2)
        }
    }
}
