import Foundation
import CoreData
@testable import esc_chatmail

/// Fluent builder for creating Message entities in tests.
///
/// Usage:
/// ```swift
/// let message = MessageBuilder()
///     .withId("test-123")
///     .withSubject("Test Email")
///     .withSender(email: "sender@example.com", name: "John Doe")
///     .unread()
///     .build(in: context)
/// ```
final class MessageBuilder {
    private var id: String = UUID().uuidString
    private var gmThreadId: String = UUID().uuidString
    private var subject: String = "Test Subject"
    private var senderEmail: String = "sender@example.com"
    private var senderName: String? = "Test Sender"
    private var snippet: String = "This is a test message snippet..."
    private var bodyText: String? = "This is the full body text of the test message."
    private var internalDate: Date = Date()
    private var isUnread: Bool = false
    private var isFromMe: Bool = false
    private var isNewsletter: Bool = false
    private var hasAttachments: Bool = false
    private var conversation: Conversation?
    private var labels: [String] = []

    // MARK: - Fluent Setters

    func withId(_ id: String) -> Self {
        self.id = id
        return self
    }

    func withThreadId(_ threadId: String) -> Self {
        self.gmThreadId = threadId
        return self
    }

    func withSubject(_ subject: String) -> Self {
        self.subject = subject
        return self
    }

    func withSender(email: String, name: String? = nil) -> Self {
        self.senderEmail = email
        self.senderName = name
        return self
    }

    func withSnippet(_ snippet: String) -> Self {
        self.snippet = snippet
        return self
    }

    func withBody(_ body: String) -> Self {
        self.bodyText = body
        return self
    }

    func withDate(_ date: Date) -> Self {
        self.internalDate = date
        return self
    }

    func daysAgo(_ days: Int) -> Self {
        self.internalDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return self
    }

    func hoursAgo(_ hours: Int) -> Self {
        self.internalDate = Calendar.current.date(byAdding: .hour, value: -hours, to: Date()) ?? Date()
        return self
    }

    func unread() -> Self {
        self.isUnread = true
        return self
    }

    func read() -> Self {
        self.isUnread = false
        return self
    }

    func fromMe() -> Self {
        self.isFromMe = true
        return self
    }

    func asNewsletter() -> Self {
        self.isNewsletter = true
        return self
    }

    func withAttachments() -> Self {
        self.hasAttachments = true
        return self
    }

    func inConversation(_ conversation: Conversation) -> Self {
        self.conversation = conversation
        return self
    }

    func withLabels(_ labels: [String]) -> Self {
        self.labels = labels
        return self
    }

    func inInbox() -> Self {
        if !labels.contains("INBOX") {
            labels.append("INBOX")
        }
        return self
    }

    func sent() -> Self {
        if !labels.contains("SENT") {
            labels.append("SENT")
        }
        return self
    }

    // MARK: - Build

    /// Builds the Message entity in the given context.
    /// - Parameter context: The managed object context to create the message in
    /// - Returns: The created Message entity
    func build(in context: NSManagedObjectContext) -> Message {
        let message = Message(context: context)
        message.id = id
        message.gmThreadId = gmThreadId
        message.subject = subject
        message.senderEmail = senderEmail
        message.senderName = senderName
        message.snippet = snippet
        message.bodyText = bodyText
        message.internalDate = internalDate
        message.isUnread = isUnread
        message.isFromMe = isFromMe
        message.isNewsletter = isNewsletter
        message.hasAttachments = hasAttachments
        message.conversation = conversation

        // Create label relationships if needed
        // Note: In real tests, you may need to fetch or create Label entities

        return message
    }
}

// MARK: - Convenience Extensions

extension MessageBuilder {
    /// Creates a simple test message with minimal configuration
    static func simple(in context: NSManagedObjectContext) -> Message {
        MessageBuilder().build(in: context)
    }

    /// Creates an unread inbox message
    static func unreadInbox(in context: NSManagedObjectContext) -> Message {
        MessageBuilder()
            .unread()
            .inInbox()
            .build(in: context)
    }

    /// Creates a sent message
    static func sentMessage(in context: NSManagedObjectContext) -> Message {
        MessageBuilder()
            .fromMe()
            .sent()
            .build(in: context)
    }
}
