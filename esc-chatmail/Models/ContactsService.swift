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
            print("Failed to request contacts access: \(error)")
            return false
        }
    }
    
    func searchContacts(query: String, limit: Int = 6) async -> [ContactMatch] {
        guard authorizationStatus == .authorized else { return [] }
        guard !query.isEmpty else { return [] }
        
        await MainActor.run {
            self.isLoadingContacts = true
        }
        
        defer {
            Task { @MainActor in
                self.isLoadingContacts = false
            }
        }
        
        let lowercasedQuery = query.lowercased()
        var matches: [ContactMatch] = []
        
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        
        request.predicate = CNContact.predicateForContacts(matchingName: query)
        
        do {
            try contactStore.enumerateContacts(with: request) { contact, stop in
                let match = ContactMatch(from: contact)
                
                let nameMatches = match.displayName.lowercased().contains(lowercasedQuery)
                let emailMatches = match.emails.contains { $0.lowercased().contains(lowercasedQuery) }
                
                if nameMatches || emailMatches {
                    matches.append(match)
                }
                
                if matches.count >= limit {
                    stop.pointee = true
                }
            }
        } catch {
            print("Failed to fetch contacts: \(error)")
        }
        
        if matches.count < limit {
            let emailRequest = CNContactFetchRequest(keysToFetch: keysToFetch)
            
            do {
                try contactStore.enumerateContacts(with: emailRequest) { contact, stop in
                    let match = ContactMatch(from: contact)
                    
                    let alreadyAdded = matches.contains { existing in
                        existing.primaryEmail == match.primaryEmail
                    }
                    
                    if !alreadyAdded {
                        let emailMatches = match.emails.contains { $0.lowercased().contains(lowercasedQuery) }
                        if emailMatches {
                            matches.append(match)
                        }
                    }
                    
                    if matches.count >= limit {
                        stop.pointee = true
                    }
                }
            } catch {
                print("Failed to search contacts by email: \(error)")
            }
        }
        
        return Array(matches.prefix(limit))
    }
    
    func getContactByEmail(_ email: String) async -> ContactMatch? {
        guard authorizationStatus == .authorized else { return nil }
        
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
            print("Failed to fetch contact by email: \(error)")
        }
        
        return nil
    }
}