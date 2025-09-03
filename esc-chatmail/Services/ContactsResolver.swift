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

final class ContactsResolver: ObservableObject, ContactsResolving, @unchecked Sendable {
    static let shared = ContactsResolver()
    
    private let contactStore = CNContactStore()
    private let cache = NSCache<NSString, ContactMatch>()
    private let viewContext: NSManagedObjectContext
    private let contactQueue = DispatchQueue(label: "com.esc.contacts", qos: .userInitiated)
    
    @MainActor @Published var authorizationStatus: CNAuthorizationStatus = .notDetermined
    
    private init() {
        self.viewContext = CoreDataStack.shared.viewContext
        self.cache.countLimit = 500
        
        // Check initial authorization status
        Task { @MainActor in
            self.authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        }
    }
    
    // MARK: - ContactsResolving
    
    func ensureAuthorization() async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        await MainActor.run {
            authorizationStatus = status
        }
        
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = try await contactStore.requestAccess(for: .contacts)
            await MainActor.run {
                authorizationStatus = granted ? .authorized : .denied
            }
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
            print("Contacts authorization failed: \(error)")
            return nil
        }
        
        // Search contacts
        let match = await searchContact(for: normalizedEmail)
        
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
    
    private func searchContact(for email: String) async -> ContactMatch? {
        return await withCheckedContinuation { continuation in
            contactQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                
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
                    // Search by email
                    let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
                    let contacts = try self.contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
                    
                    // Find best match
                    if let contact = self.findBestContact(from: contacts, for: email) {
                        let match = self.createMatch(from: contact, email: email)
                        continuation.resume(returning: match)
                        return
                    }
                    
                    // If no exact match, try broader search
                    let request = CNContactFetchRequest(keysToFetch: keysToFetch)
                    var allContacts: [CNContact] = []
                    
                    try self.contactStore.enumerateContacts(with: request) { contact, _ in
                        for emailAddress in contact.emailAddresses {
                            let contactEmail = EmailNormalizer.normalize(emailAddress.value as String)
                            if contactEmail == EmailNormalizer.normalize(email) {
                                allContacts.append(contact)
                                return
                            }
                        }
                    }
                    
                    if let contact = self.findBestContact(from: allContacts, for: email) {
                        let match = self.createMatch(from: contact, email: email)
                        continuation.resume(returning: match)
                        return
                    }
                    
                } catch {
                    print("Error fetching contacts: \(error)")
                }
                
                continuation.resume(returning: nil)
            }
        }
    }
    
    private func findBestContact(from contacts: [CNContact], for email: String) -> CNContact? {
        guard !contacts.isEmpty else { return nil }
        
        let normalizedEmail = EmailNormalizer.normalize(email)
        
        // Prefer exact email match
        for contact in contacts {
            for emailAddress in contact.emailAddresses {
                if EmailNormalizer.normalize(emailAddress.value as String) == normalizedEmail {
                    // Prefer work or iCloud labeled emails
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
        // Get display name
        let displayName = CNContactFormatter.string(from: contact, style: .fullName)
        
        // Get image data
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
        await withCheckedContinuation { continuation in
            viewContext.perform { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                
                let request = Person.fetchRequest()
                request.predicate = NSPredicate(format: "email == %@", email)
                
                do {
                    if let person = try self.viewContext.fetch(request).first {
                        var hasChanges = false
                        
                        // Only update if we have new data and existing is empty
                        if person.displayName == nil || person.displayName?.isEmpty == true,
                           let displayName = match.displayName {
                            person.displayName = displayName
                            hasChanges = true
                        }
                        
                        if person.avatarURL == nil && match.imageData != nil {
                            // Store image data as base64 URL for now
                            // In production, save to file and store URL
                            if let imageData = match.imageData {
                                let base64String = imageData.base64EncodedString()
                                person.avatarURL = "data:image/png;base64,\(base64String)"
                                hasChanges = true
                            }
                        }
                        
                        // Only save if there are actual changes
                        if hasChanges && self.viewContext.hasChanges {
                            try self.viewContext.save()
                        }
                    }
                } catch {
                    print("Failed to update Person: \(error)")
                }
                
                continuation.resume()
            }
        } as Void
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
}