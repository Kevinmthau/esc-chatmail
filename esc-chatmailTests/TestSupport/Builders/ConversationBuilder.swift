import Foundation
import CoreData
@testable import esc_chatmail

/// Fluent builder for creating Conversation entities in tests.
///
/// Usage:
/// ```swift
/// let conversation = ConversationBuilder()
///     .withDisplayName("John Doe")
///     .withParticipantHash("hash123")
///     .visible()
///     .build(in: context)
/// ```
final class ConversationBuilder {
    private var id: UUID = UUID()
    private var keyHash: String = UUID().uuidString
    private var participantHash: String?
    private var displayName: String?
    private var snippet: String?
    private var lastMessageDate: Date?
    private var latestInboxDate: Date?
    private var archivedAt: Date?
    private var hasInbox: Bool = true
    private var hidden: Bool = false
    private var muted: Bool = false
    private var pinned: Bool = false
    private var inboxUnreadCount: Int32 = 0
    private var type: String = "personal"

    // MARK: - Fluent Setters

    func withId(_ id: UUID) -> Self {
        self.id = id
        return self
    }

    func withKeyHash(_ keyHash: String) -> Self {
        self.keyHash = keyHash
        return self
    }

    func withParticipantHash(_ participantHash: String) -> Self {
        self.participantHash = participantHash
        return self
    }

    func withDisplayName(_ displayName: String) -> Self {
        self.displayName = displayName
        return self
    }

    func withSnippet(_ snippet: String) -> Self {
        self.snippet = snippet
        return self
    }

    func withLastMessageDate(_ date: Date) -> Self {
        self.lastMessageDate = date
        return self
    }

    func recentlyActive() -> Self {
        self.lastMessageDate = Date()
        self.latestInboxDate = Date()
        return self
    }

    func daysAgo(_ days: Int) -> Self {
        let date = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        self.lastMessageDate = date
        return self
    }

    func visible() -> Self {
        self.archivedAt = nil
        self.hidden = false
        return self
    }

    func archived() -> Self {
        self.archivedAt = Date()
        return self
    }

    func archivedOn(_ date: Date) -> Self {
        self.archivedAt = date
        return self
    }

    func setHidden() -> Self {
        self.hidden = true
        return self
    }

    func setMuted() -> Self {
        self.muted = true
        return self
    }

    func setPinned() -> Self {
        self.pinned = true
        return self
    }

    func withUnreadCount(_ count: Int32) -> Self {
        self.inboxUnreadCount = count
        return self
    }

    func hasInboxMessages(_ hasInbox: Bool = true) -> Self {
        self.hasInbox = hasInbox
        return self
    }

    func asNewsletter() -> Self {
        self.type = "newsletter"
        return self
    }

    func asPersonal() -> Self {
        self.type = "personal"
        return self
    }

    // MARK: - Build

    /// Builds the Conversation entity in the given context.
    /// - Parameter context: The managed object context to create the conversation in
    /// - Returns: The created Conversation entity
    func build(in context: NSManagedObjectContext) -> Conversation {
        let conversation = Conversation(context: context)
        conversation.id = id
        conversation.keyHash = keyHash
        conversation.participantHash = participantHash
        conversation.displayName = displayName
        conversation.snippet = snippet
        conversation.lastMessageDate = lastMessageDate
        conversation.latestInboxDate = latestInboxDate
        conversation.archivedAt = archivedAt
        conversation.hasInbox = hasInbox
        conversation.hidden = hidden
        conversation.muted = muted
        conversation.pinned = pinned
        conversation.inboxUnreadCount = inboxUnreadCount
        conversation.type = type

        return conversation
    }
}

// MARK: - Convenience Extensions

extension ConversationBuilder {
    /// Creates a simple visible conversation with minimal configuration
    static func simple(in context: NSManagedObjectContext) -> Conversation {
        ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: context)
    }

    /// Creates an archived conversation
    static func archivedConversation(in context: NSManagedObjectContext) -> Conversation {
        ConversationBuilder()
            .archived()
            .daysAgo(7)
            .build(in: context)
    }

    /// Creates a pinned conversation
    static func pinnedConversation(in context: NSManagedObjectContext) -> Conversation {
        ConversationBuilder()
            .visible()
            .setPinned()
            .recentlyActive()
            .build(in: context)
    }
}
