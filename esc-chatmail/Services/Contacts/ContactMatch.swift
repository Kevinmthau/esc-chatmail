import Foundation

// MARK: - Protocol

/// Protocol for contact resolution services.
/// Enables dependency injection and testing.
protocol ContactsResolving {
    /// Ensures the app has authorization to access contacts.
    func ensureAuthorization() async throws

    /// Looks up contact information for an email address.
    /// - Parameter email: The email address to look up
    /// - Returns: A ContactMatch if found, nil otherwise
    func lookup(email: String) async -> ContactMatch?

    /// Pre-warms the cache by fetching contacts for multiple emails.
    /// - Parameter emails: The email addresses to look up
    func prewarm(emails: [String]) async
}

// MARK: - Contact Match

/// Represents a matched contact from the system address book.
/// Contains display name, email, and optional avatar image data.
class ContactMatch: NSObject {
    /// The contact's display name from the address book
    let displayName: String?

    /// The normalized email address
    let email: String

    /// Thumbnail image data for the contact's avatar
    let imageData: Data?

    /// The CNContact identifier for future reference
    let contactIdentifier: String?

    init(displayName: String?, email: String, imageData: Data?, contactIdentifier: String? = nil) {
        self.displayName = displayName
        self.email = email
        self.imageData = imageData
        self.contactIdentifier = contactIdentifier
        super.init()
    }
}

// MARK: - Errors

/// Errors that can occur during contact access.
enum ContactsError: LocalizedError {
    case accessDenied
    case accessRestricted
    case accessNotDetermined

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access to contacts was denied. Please enable in Settings."
        case .accessRestricted:
            return "Access to contacts is restricted."
        case .accessNotDetermined:
            return "Contacts access has not been determined."
        }
    }
}
