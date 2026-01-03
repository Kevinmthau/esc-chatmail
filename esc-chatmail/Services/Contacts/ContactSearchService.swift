import Foundation
import Contacts

/// Extension containing contact search logic for ContactsResolver.
///
/// These methods handle the actual CNContact lookups and matching.
/// All methods run synchronously within the actor's isolation.
extension ContactsResolver {

    /// Searches for a contact by email address.
    /// Runs synchronously within actor isolation.
    /// - Parameter email: The normalized email to search for
    /// - Returns: A ContactMatch if found
    func searchContact(for email: String) -> ContactMatch? {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor,
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

    /// Finds the best matching contact from a list.
    /// Prefers contacts with work or iCloud email labels.
    func findBestContact(from contacts: [CNContact], for email: String) -> CNContact? {
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

    /// Creates a ContactMatch from a CNContact.
    func createMatch(from contact: CNContact, email: String) -> ContactMatch {
        let displayName = CNContactFormatter.string(from: contact, style: .fullName)

        var imageData: Data?
        if contact.imageDataAvailable {
            imageData = contact.thumbnailImageData
        }

        return ContactMatch(
            displayName: displayName,
            email: EmailNormalizer.normalize(email),
            imageData: imageData,
            contactIdentifier: contact.identifier
        )
    }

    /// Performs batch contact lookup for avatar data.
    /// Uses different strategies for small vs large batches.
    func performBatchLookup(for normalizedEmails: Set<String>) -> [String: Data] {
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
