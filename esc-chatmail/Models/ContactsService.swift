import Foundation
import Contacts
import Combine

final class ContactsService: ObservableObject {
    @Published var authorizationStatus: CNAuthorizationStatus = .notDetermined
    @Published var isLoadingContacts = false
    
    private let contactStore = CNContactStore()
    private let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactThumbnailImageDataKey as CNKeyDescriptor
    ]
    
    struct ContactMatch: Identifiable {
        let id = UUID()
        let displayName: String
        let emails: [String]
        let primaryEmail: String
        let imageData: Data?
        let imageDataAvailable: Bool
        
        init(from cnContact: CNContact) {
            let givenName = cnContact.givenName
            let familyName = cnContact.familyName
            
            if !givenName.isEmpty && !familyName.isEmpty {
                self.displayName = "\(givenName) \(familyName)"
            } else if !givenName.isEmpty {
                self.displayName = givenName
            } else if !familyName.isEmpty {
                self.displayName = familyName
            } else {
                self.displayName = cnContact.emailAddresses.first?.value as String? ?? "Unknown"
            }
            
            self.emails = cnContact.emailAddresses.map { $0.value as String }
            self.primaryEmail = self.emails.first ?? ""
            self.imageData = cnContact.thumbnailImageData
            self.imageDataAvailable = cnContact.thumbnailImageData != nil
        }
    }
    
    init() {
        checkAuthorizationStatus()
    }
    
    func checkAuthorizationStatus() {
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    }
    
    func requestAccess() async -> Bool {
        do {
            let granted = try await contactStore.requestAccess(for: .contacts)
            await MainActor.run {
                self.authorizationStatus = granted ? .authorized : .denied
            }
            return granted
        } catch {
            Log.error("Failed to request contacts access", category: .general, error: error)
            return false
        }
    }
    
    func searchContacts(query: String) async -> [ContactMatch] {
        guard authorizationStatus == .authorized else { return [] }
        guard !query.isEmpty else { return [] }

        await MainActor.run {
            self.isLoadingContacts = true
        }

        // Move blocking CNContactStore operations to background thread
        // enumerateContacts is synchronous and will block the calling thread
        let results = await Task.detached(priority: .userInitiated) { [keysToFetch, contactStore] in
            Self.performContactSearch(
                query: query,
                keysToFetch: keysToFetch,
                contactStore: contactStore
            )
        }.value

        await MainActor.run {
            self.isLoadingContacts = false
        }

        return results
    }

    /// Synchronous contact search - must be called from background thread
    private static func performContactSearch(
        query: String,
        keysToFetch: [CNKeyDescriptor],
        contactStore: CNContactStore
    ) -> [ContactMatch] {
        let lowercasedQuery = query.lowercased()
        var matches: [ContactMatch] = []
        var addedEmails = Set<String>()

        // First search by name predicate
        let nameRequest = CNContactFetchRequest(keysToFetch: keysToFetch)
        nameRequest.predicate = CNContact.predicateForContacts(matchingName: query)

        do {
            try contactStore.enumerateContacts(with: nameRequest) { contact, _ in
                let match = ContactMatch(from: contact)

                let nameMatches = match.displayName.lowercased().contains(lowercasedQuery)
                let emailMatches = match.emails.contains { $0.lowercased().contains(lowercasedQuery) }

                if (nameMatches || emailMatches) && !addedEmails.contains(match.primaryEmail) {
                    matches.append(match)
                    addedEmails.insert(match.primaryEmail)
                }
            }
        } catch {
            Log.error("Failed to fetch contacts", category: .general, error: error)
        }

        // Also search by email to catch contacts not matched by name
        let emailRequest = CNContactFetchRequest(keysToFetch: keysToFetch)

        do {
            try contactStore.enumerateContacts(with: emailRequest) { contact, _ in
                let match = ContactMatch(from: contact)

                if !addedEmails.contains(match.primaryEmail) {
                    let emailMatches = match.emails.contains { $0.lowercased().contains(lowercasedQuery) }
                    if emailMatches {
                        matches.append(match)
                        addedEmails.insert(match.primaryEmail)
                    }
                }
            }
        } catch {
            Log.error("Failed to search contacts by email", category: .general, error: error)
        }

        return matches
    }
    
    func getContactByEmail(_ email: String) async -> ContactMatch? {
        guard authorizationStatus == .authorized else { return nil }

        // Move blocking CNContactStore operation to background thread
        return await Task.detached(priority: .userInitiated) { [keysToFetch, contactStore] in
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            request.predicate = predicate

            do {
                var foundContact: CNContact?
                try contactStore.enumerateContacts(with: request) { contact, stop in
                    foundContact = contact
                    stop.pointee = true
                }

                if let contact = foundContact {
                    return ContactMatch(from: contact)
                }
            } catch {
                Log.error("Failed to fetch contact by email", category: .general, error: error)
            }

            return nil
        }.value
    }
}