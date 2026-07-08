import Foundation

// MARK: - Protocol

/// Protocol for contact resolution services.
/// Enables dependency injection and testing.
protocol ContactsResolving: Sendable {
    /// Verifies the app has authorization to access contacts. Must never
    /// present the system permission dialog: `.notDetermined` throws so
    /// callers degrade gracefully until an explicit request runs.
    func ensureAuthorization() async throws

    /// Looks up contact information for an email address.
    /// - Parameter email: The email address to look up
    /// - Returns: A ContactMatch if found, nil otherwise
    func lookup(email: String) async -> ContactMatch?

    /// Pre-warms the cache by fetching contacts for multiple emails.
    /// - Parameter emails: The email addresses to look up
    func prewarm(emails: [String]) async

    /// Resolves just the avatar data for an email.
    func resolveAvatarData(for email: String) async -> Data?

    /// Batch resolve avatar data for multiple emails, keyed by normalized email.
    func resolveAvatarDataBatch(for emails: [String]) async -> [String: Data]
}

extension ContactsResolving {
    // Defaults delegate to `lookup`. These are protocol requirements (not just
    // extension conveniences) so ContactsResolver's batched CNContactStore
    // implementation is reached through `any ContactsResolving`.

    func resolveAvatarData(for email: String) async -> Data? {
        await lookup(email: email)?.imageData
    }

    func resolveAvatarDataBatch(for emails: [String]) async -> [String: Data] {
        var results: [String: Data] = [:]
        for email in Set(emails.map { EmailNormalizer.normalize($0) }) {
            if let data = await lookup(email: email)?.imageData {
                results[email] = data
            }
        }
        return results
    }
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
