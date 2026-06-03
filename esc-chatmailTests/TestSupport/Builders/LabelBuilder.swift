import Foundation
import CoreData
@testable import esc_chatmail

/// Fluent builder for creating Label entities in tests.
///
/// Usage:
/// ```swift
/// let label = LabelBuilder()
///     .withId("INBOX")
///     .withName("Inbox")
///     .build(in: context)
/// ```
final class LabelBuilder {
    private var id: String = "CUSTOM_LABEL"
    private var name: String = "Custom Label"

    // MARK: - Fluent Setters

    func withId(_ id: String) -> Self {
        self.id = id
        return self
    }

    func withName(_ name: String) -> Self {
        self.name = name
        return self
    }

    // MARK: - System Label Presets

    func inbox() -> Self {
        self.id = "INBOX"
        self.name = "Inbox"
        return self
    }

    func sent() -> Self {
        self.id = "SENT"
        self.name = "Sent"
        return self
    }

    func draft() -> Self {
        self.id = "DRAFT"
        self.name = "Draft"
        return self
    }

    func spam() -> Self {
        self.id = "SPAM"
        self.name = "Spam"
        return self
    }

    func trash() -> Self {
        self.id = "TRASH"
        self.name = "Trash"
        return self
    }

    func unread() -> Self {
        self.id = "UNREAD"
        self.name = "Unread"
        return self
    }

    func starred() -> Self {
        self.id = "STARRED"
        self.name = "Starred"
        return self
    }

    func important() -> Self {
        self.id = "IMPORTANT"
        self.name = "Important"
        return self
    }

    // MARK: - Build

    /// Builds the Label entity in the given context.
    /// - Parameter context: The managed object context to create the label in
    /// - Returns: The created Label entity
    @discardableResult
    func build(in context: NSManagedObjectContext) -> Label {
        let label = context.insertTestObject(Label.self)
        label.id = id
        label.name = name
        return label
    }
}

// MARK: - Convenience Extensions

extension LabelBuilder {
    /// Creates a simple custom label
    static func simple(in context: NSManagedObjectContext) -> Label {
        LabelBuilder().build(in: context)
    }

    /// Creates an INBOX label
    static func inboxLabel(in context: NSManagedObjectContext) -> Label {
        LabelBuilder().inbox().build(in: context)
    }

    /// Creates a SENT label
    static func sentLabel(in context: NSManagedObjectContext) -> Label {
        LabelBuilder().sent().build(in: context)
    }

    /// Creates an UNREAD label
    static func unreadLabel(in context: NSManagedObjectContext) -> Label {
        LabelBuilder().unread().build(in: context)
    }

    /// Creates a custom label with the given ID and name
    static func custom(id: String, name: String, in context: NSManagedObjectContext) -> Label {
        LabelBuilder()
            .withId(id)
            .withName(name)
            .build(in: context)
    }
}
