import Foundation
import CoreData
@testable import esc_chatmail

/// Fluent builder for creating PendingAction entities in tests.
///
/// Usage:
/// ```swift
/// let action = PendingActionBuilder()
///     .markAsRead()
///     .forMessage("msg-123")
///     .build(in: context)
/// ```
final class PendingActionBuilder {
    private var id: UUID = UUID()
    private var actionType: String = "markRead"
    private var messageId: String?
    private var conversationId: UUID?
    private var payload: String?
    private var status: String = "pending"
    private var retryCount: Int16 = 0
    private var createdAt: Date = Date()
    private var lastAttempt: Date?

    // MARK: - Fluent Setters

    func withId(_ id: UUID) -> Self {
        self.id = id
        return self
    }

    // MARK: - Action Types

    func markAsRead() -> Self {
        self.actionType = "markRead"
        return self
    }

    func markAsUnread() -> Self {
        self.actionType = "markUnread"
        return self
    }

    func archive() -> Self {
        self.actionType = "archive"
        return self
    }

    func unarchive() -> Self {
        self.actionType = "unarchive"
        return self
    }

    func trash() -> Self {
        self.actionType = "trash"
        return self
    }

    func modifyLabels() -> Self {
        self.actionType = "modifyLabels"
        return self
    }

    func send() -> Self {
        self.actionType = "send"
        return self
    }

    func withActionType(_ type: String) -> Self {
        self.actionType = type
        return self
    }

    // MARK: - Target

    func forMessage(_ messageId: String) -> Self {
        self.messageId = messageId
        return self
    }

    func forConversation(_ conversationId: UUID) -> Self {
        self.conversationId = conversationId
        return self
    }

    // MARK: - Payload

    func withPayload(_ payload: String) -> Self {
        self.payload = payload
        return self
    }

    func withPayload<T: Encodable>(_ payload: T) -> Self {
        if let data = try? JSONEncoder().encode(payload),
           let json = String(data: data, encoding: .utf8) {
            self.payload = json
        }
        return self
    }

    // MARK: - Status

    func pending() -> Self {
        self.status = "pending"
        return self
    }

    func inProgress() -> Self {
        self.status = "inProgress"
        return self
    }

    func completed() -> Self {
        self.status = "completed"
        return self
    }

    func failed() -> Self {
        self.status = "failed"
        return self
    }

    func withStatus(_ status: String) -> Self {
        self.status = status
        return self
    }

    // MARK: - Retry

    func withRetryCount(_ count: Int16) -> Self {
        self.retryCount = count
        return self
    }

    func failedOnce() -> Self {
        self.retryCount = 1
        self.lastAttempt = Date().addingTimeInterval(-60) // 1 minute ago
        return self
    }

    func failedMultipleTimes(_ count: Int16) -> Self {
        self.retryCount = count
        self.lastAttempt = Date().addingTimeInterval(-60)
        return self
    }

    // MARK: - Timing

    func createdAt(_ date: Date) -> Self {
        self.createdAt = date
        return self
    }

    func createdMinutesAgo(_ minutes: Int) -> Self {
        self.createdAt = Date().addingTimeInterval(TimeInterval(-minutes * 60))
        return self
    }

    func withLastAttempt(_ date: Date) -> Self {
        self.lastAttempt = date
        return self
    }

    // MARK: - Build

    /// Builds the PendingAction entity in the given context.
    /// - Parameter context: The managed object context to create the action in
    /// - Returns: The created PendingAction entity
    func build(in context: NSManagedObjectContext) -> PendingAction {
        let action = PendingAction(context: context)
        action.id = id
        action.actionType = actionType
        action.messageId = messageId
        action.conversationId = conversationId
        action.payload = payload
        action.status = status
        action.retryCount = retryCount
        action.createdAt = createdAt
        action.lastAttempt = lastAttempt

        return action
    }
}

// MARK: - Convenience Extensions

extension PendingActionBuilder {
    /// Creates a simple pending action
    static func simple(in context: NSManagedObjectContext) -> PendingAction {
        PendingActionBuilder()
            .markAsRead()
            .forMessage("test-message-id")
            .pending()
            .build(in: context)
    }

    /// Creates a failed action ready for retry
    static func failedAction(in context: NSManagedObjectContext) -> PendingAction {
        PendingActionBuilder()
            .markAsRead()
            .forMessage("test-message-id")
            .failed()
            .failedOnce()
            .build(in: context)
    }

    /// Creates a pending archive action
    static func archiveAction(for conversationId: UUID, in context: NSManagedObjectContext) -> PendingAction {
        PendingActionBuilder()
            .archive()
            .forConversation(conversationId)
            .pending()
            .build(in: context)
    }
}
