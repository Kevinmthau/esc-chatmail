import Foundation
import Contacts

/// Unified recipient model for message composition
/// Consolidates RecipientField.Recipient, RecipientToken, and inline tuples
struct Recipient: Identifiable, Equatable, Hashable {
    let id: UUID
    let email: String
    let displayName: String?
    let isValid: Bool

    /// Display text - shows name if available, otherwise email
    var display: String {
        if let displayName = displayName, !displayName.isEmpty {
            return displayName
        }
        return email
    }

    /// Initialize with email and optional display name
    /// Email is automatically normalized and validated
    init(email: String, displayName: String? = nil) {
        self.id = UUID()
        self.email = EmailNormalizer.normalize(email)
        self.displayName = displayName
        self.isValid = EmailValidator.isValid(email)
    }

    /// Initialize from a system contact
    init(from contact: CNContact) {
        self.id = UUID()
        let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
        let emailValue = contact.emailAddresses.first?.value as String? ?? ""

        self.email = EmailNormalizer.normalize(emailValue)
        self.displayName = fullName.isEmpty ? nil : fullName
        self.isValid = EmailValidator.isValid(emailValue)
    }

    /// Initialize from a Person Core Data entity
    init(from person: Person) {
        self.id = UUID()
        self.email = EmailNormalizer.normalize(person.email)
        self.displayName = person.name
        self.isValid = EmailValidator.isValid(person.email)
    }

    /// Initialize from ContactsService.ContactMatch
    init(from match: ContactsService.ContactMatch, email: String? = nil) {
        self.id = UUID()
        let selectedEmail = email ?? match.primaryEmail
        self.email = EmailNormalizer.normalize(selectedEmail)
        self.displayName = match.displayName
        self.isValid = EmailValidator.isValid(selectedEmail)
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(email)
    }

    static func == (lhs: Recipient, rhs: Recipient) -> Bool {
        lhs.email == rhs.email
    }
}
