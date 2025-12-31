import Foundation
import Contacts
import CoreData

// MARK: - Protocols

protocol ContactsResolving {
    func ensureAuthorization() async throws
    func lookup(email: String) async -> ContactMatch?
    func prewarm(emails: [String]) async
}

class ContactMatch: NSObject {
    let displayName: String?
    let email: String
    let imageData: Data?

    init(displayName: String?, email: String, imageData: Data?) {
        self.displayName = displayName
        self.email = email
        self.imageData = imageData
        super.init()
    }
}

// MARK: - Errors

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

// MARK: - ContactsResolver

/// Actor-based contacts resolver for avatar and display name lookup.
/// Uses actor isolation instead of manual DispatchQueue synchronization.
actor ContactsResolver: ContactsResolving {
    static let shared = ContactsResolver()

    private let contactStore = CNContactStore()
    private let cache = NSCache<NSString, ContactMatch>()
    private let coreDataStack: CoreDataStack
    private var authorizationStatus: CNAuthorizationStatus

    private init() {
        self.coreDataStack = CoreDataStack.shared
        self.cache.countLimit = 500
        self.authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    }

    // MARK: - ContactsResolving

    func ensureAuthorization() async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        authorizationStatus = status

        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = try await contactStore.requestAccess(for: .contacts)
            authorizationStatus = granted ? .authorized : .denied
            if !granted {
                throw ContactsError.accessDenied
            }
        case .denied:
            throw ContactsError.accessDenied
        case .restricted:
            throw ContactsError.accessRestricted
        case .limited:
            // Limited access is treated as authorized for our purposes
            return
        @unknown default:
            throw ContactsError.accessDenied
        }
    }

    func lookup(email: String) async -> ContactMatch? {
        let normalizedEmail = EmailNormalizer.normalize(email)

        // Check cache first
        if let cached = cache.object(forKey: normalizedEmail as NSString) {
            return cached
        }

        // Ensure we have authorization
        do {
            try await ensureAuthorization()
        } catch {
            Log.warning("Contacts authorization failed: \(error)", category: .general)
            return nil
        }

        // Search contacts (actor provides serialization)
        let match = searchContact(for: normalizedEmail)

        // Cache the result
        if let match = match {
            cache.setObject(match, forKey: normalizedEmail as NSString)

            // Update Person in Core Data
            await updatePerson(email: normalizedEmail, match: match)
        }

        return match
    }

    func prewarm(emails: [String]) async {
        // Batch fetch contacts for multiple emails
        for email in emails {
            _ = await lookup(email: email)
        }
    }

    // MARK: - Private Methods

    /// Searches for a contact by email. Runs synchronously within actor isolation.
    private func searchContact(for email: String) -> ContactMatch? {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]

        do {
            // Search by email predicate first (faster)
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
            let contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)

            // Find best match
            if let contact = findBestContact(from: contacts, for: email) {
                return createMatch(from: contact, email: email)
            }

            // If no exact match, try broader search
            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            var allContacts: [CNContact] = []

            try contactStore.enumerateContacts(with: request) { contact, _ in
                for emailAddress in contact.emailAddresses {
                    let contactEmail = EmailNormalizer.normalize(emailAddress.value as String)
                    if contactEmail == EmailNormalizer.normalize(email) {
                        allContacts.append(contact)
                        return
                    }
                }
            }

            if let contact = findBestContact(from: allContacts, for: email) {
                return createMatch(from: contact, email: email)
            }

        } catch {
            Log.error("Error fetching contacts", category: .general, error: error)
        }

        return nil
    }

    private func findBestContact(from contacts: [CNContact], for email: String) -> CNContact? {
        guard !contacts.isEmpty else { return nil }

        let normalizedEmail = EmailNormalizer.normalize(email)

        // Prefer exact email match with work or iCloud label
        for contact in contacts {
            for emailAddress in contact.emailAddresses {
                if EmailNormalizer.normalize(emailAddress.value as String) == normalizedEmail {
                    if let label = emailAddress.label {
                        if label == CNLabelWork || label.contains("iCloud") {
                            return contact
                        }
                    }
                }
            }
        }

        // Return first match
        return contacts.first
    }

    private func createMatch(from contact: CNContact, email: String) -> ContactMatch {
        let displayName = CNContactFormatter.string(from: contact, style: .fullName)

        var imageData: Data?
        if contact.imageDataAvailable {
            imageData = contact.thumbnailImageData
        }

        return ContactMatch(
            displayName: displayName,
            email: EmailNormalizer.normalize(email),
            imageData: imageData
        )
    }

    private func updatePerson(email: String, match: ContactMatch) async {
        let displayName = match.displayName
        let imageData = match.imageData
        let context = coreDataStack.newBackgroundContext()

        await context.perform {
            let request = Person.fetchRequest()
            request.predicate = NSPredicate(format: "email == %@", email)

            do {
                if let person = try context.fetch(request).first {
                    var hasChanges = false

                    // Address book name always takes precedence over email header name
                    if let displayName = displayName, !displayName.isEmpty,
                       person.displayName != displayName {
                        person.displayName = displayName
                        hasChanges = true
                    }

                    if person.avatarURL == nil && imageData != nil {
                        // Store image as file and save URL to avoid base64 bloat
                        if let imageData = imageData,
                           let fileURL = AvatarStorage.shared.saveAvatar(for: email, imageData: imageData) {
                            person.avatarURL = fileURL
                            hasChanges = true
                        }
                    }

                    // Only save if there are actual changes
                    if hasChanges && context.hasChanges {
                        try context.save()
                    }
                }
            } catch {
                Log.error("Failed to update Person", category: .general, error: error)
            }
        }
    }
}

// MARK: - Helper Extensions

extension ContactsResolver {
    func resolveDisplayName(for email: String) async -> String {
        if let match = await lookup(email: email),
           let displayName = match.displayName,
           !displayName.isEmpty {
            return displayName
        }

        // Fallback to email local part
        let normalized = EmailNormalizer.normalize(email)
        if let atIndex = normalized.firstIndex(of: "@") {
            return String(normalized[..<atIndex])
        }

        return email
    }

    func resolveAvatarData(for email: String) async -> Data? {
        return await lookup(email: email)?.imageData
    }

    /// Batch resolve avatar data for multiple emails.
    /// Much more efficient than individual lookups when prefetching.
    func resolveAvatarDataBatch(for emails: [String]) async -> [String: Data] {
        guard !emails.isEmpty else { return [:] }

        // Ensure we have authorization
        do {
            try await ensureAuthorization()
        } catch {
            Log.warning("Contacts authorization failed for batch lookup: \(error)", category: .general)
            return [:]
        }

        let normalizedEmails = Set(emails.map { EmailNormalizer.normalize($0) })

        // Actor provides isolation - no need for DispatchQueue
        return performBatchLookup(for: normalizedEmails)
    }

    /// Performs batch contact lookup. Runs synchronously within actor isolation.
    private func performBatchLookup(for normalizedEmails: Set<String>) -> [String: Data] {
        var results: [String: Data] = [:]

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]

        // For large batches, enumerate all contacts once (more efficient than N predicates)
        // For small batches, use individual predicates
        if normalizedEmails.count > 10 {
            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            do {
                try contactStore.enumerateContacts(with: request) { contact, _ in
                    guard contact.imageDataAvailable,
                          let imageData = contact.thumbnailImageData else { return }

                    for emailAddress in contact.emailAddresses {
                        let contactEmail = EmailNormalizer.normalize(emailAddress.value as String)
                        if normalizedEmails.contains(contactEmail) {
                            results[contactEmail] = imageData
                        }
                    }
                }
            } catch {
                Log.error("Batch contact enumeration failed", category: .general, error: error)
            }
        } else {
            // For smaller batches, use individual predicates (avoids full scan)
            for email in normalizedEmails {
                do {
                    let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
                    let contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
                    if let contact = contacts.first,
                       contact.imageDataAvailable,
                       let imageData = contact.thumbnailImageData {
                        results[email] = imageData
                    }
                } catch {
                    // Individual lookup failed, continue with others
                    continue
                }
            }
        }

        return results
    }
}
