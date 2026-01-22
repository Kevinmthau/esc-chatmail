import Foundation
import CoreData
@testable import esc_chatmail

/// Fluent builder for creating Person entities in tests.
///
/// Usage:
/// ```swift
/// let person = PersonBuilder()
///     .withEmail("john@example.com")
///     .withDisplayName("John Doe")
///     .build(in: context)
/// ```
final class PersonBuilder {
    private var id: UUID = UUID()
    private var email: String = "test@example.com"
    private var displayName: String? = "Test Person"
    private var avatarURL: String?

    // MARK: - Fluent Setters

    func withId(_ id: UUID) -> Self {
        self.id = id
        return self
    }

    func withEmail(_ email: String) -> Self {
        self.email = email
        return self
    }

    func withDisplayName(_ name: String?) -> Self {
        self.displayName = name
        return self
    }

    func withAvatarURL(_ url: String?) -> Self {
        self.avatarURL = url
        return self
    }

    func noDisplayName() -> Self {
        self.displayName = nil
        return self
    }

    // MARK: - Build

    /// Builds the Person entity in the given context.
    /// - Parameter context: The managed object context to create the person in
    /// - Returns: The created Person entity
    func build(in context: NSManagedObjectContext) -> Person {
        let person = Person(context: context)
        person.id = id
        person.email = email
        person.displayName = displayName
        person.avatarURL = avatarURL
        return person
    }
}

// MARK: - Convenience Extensions

extension PersonBuilder {
    /// Creates a simple test person with minimal configuration
    static func simple(in context: NSManagedObjectContext) -> Person {
        PersonBuilder().build(in: context)
    }

    /// Creates a person with only an email (no display name)
    static func emailOnly(_ email: String, in context: NSManagedObjectContext) -> Person {
        PersonBuilder()
            .withEmail(email)
            .noDisplayName()
            .build(in: context)
    }

    /// Creates a person with full name and email
    static func named(_ name: String, email: String, in context: NSManagedObjectContext) -> Person {
        PersonBuilder()
            .withEmail(email)
            .withDisplayName(name)
            .build(in: context)
    }
}
