import SwiftUI
import Contacts

struct ContactSearchResults: View {
    let query: String
    let existingRecipients: [Recipient]
    let onSelect: (CNContact) -> Void
    
    @State private var searchResults: [CNContact] = []
    @State private var isSearching = false
    @State private var contactStore = CNContactStore()
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if isSearching {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Searching...")
                            .font(.system(size: 15))
                            .foregroundColor(Color(.secondaryLabel))
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else if searchResults.isEmpty {
                    Text("No contacts found")
                        .font(.system(size: 15))
                        .foregroundColor(Color(.secondaryLabel))
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    ForEach(searchResults, id: \.identifier) { contact in
                        MessageContactRow(contact: contact) {
                            onSelect(contact)
                        }
                        .disabled(isAlreadyAdded(contact))
                    }
                }
            }
        }
        .frame(maxHeight: 200)
        .background(Color(.systemBackground))
        .onAppear {
            requestContactsAccess()
            searchContacts()
        }
        .onChange(of: query) {
            searchContacts()
        }
    }
    
    private func isAlreadyAdded(_ contact: CNContact) -> Bool {
        let contactEmail = contact.emailAddresses.first?.value as String? ?? ""
        return existingRecipients.contains { $0.email == contactEmail }
    }
    
    private func requestContactsAccess() {
        Task {
            await withCheckedContinuation { continuation in
                contactStore.requestAccess(for: .contacts) { granted, error in
                    if let error = error {
                        Log.error("Failed to request contacts access", category: .general, error: error)
                    } else if !granted {
                        Log.warning("Contacts access denied", category: .general)
                    }
                    continuation.resume()
                }
            }
        }
    }
    
    private func searchContacts() {
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        
        Task {
            do {
                let keysToFetch = [
                    CNContactGivenNameKey,
                    CNContactFamilyNameKey,
                    CNContactEmailAddressesKey,
                    CNContactThumbnailImageDataKey,
                    CNContactImageDataAvailableKey
                ] as [CNKeyDescriptor]
                
                let predicate = CNContact.predicateForContacts(matchingName: query)
                
                let contacts = try contactStore.unifiedContacts(
                    matching: predicate,
                    keysToFetch: keysToFetch
                )
                
                // Filter to only contacts with email addresses
                let contactsWithEmail = contacts.filter { !$0.emailAddresses.isEmpty }
                
                // Also search by email if query looks like an email
                var allContacts = contactsWithEmail
                if query.contains("@") {
                    let emailPredicate = CNContact.predicateForContacts(matchingEmailAddress: query)
                    let emailContacts = try contactStore.unifiedContacts(
                        matching: emailPredicate,
                        keysToFetch: keysToFetch
                    )
                    allContacts.append(contentsOf: emailContacts)
                }
                
                // Remove duplicates
                let uniqueContacts = Array(Set(allContacts))
                
                await MainActor.run {
                    searchResults = uniqueContacts.sorted { contact1, contact2 in
                        let name1 = "\(contact1.givenName) \(contact1.familyName)"
                        let name2 = "\(contact2.givenName) \(contact2.familyName)"
                        return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
                    }
                    isSearching = false
                }
            } catch {
                Log.error("Failed to search contacts", category: .general, error: error)
                await MainActor.run {
                    searchResults = []
                    isSearching = false
                }
            }
        }
    }
}

struct MessageContactRow: View {
    let contact: CNContact
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Avatar
                if let imageData = contact.thumbnailImageData,
                   let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                } else {
                    ZStack {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: 36, height: 36)
                        
                        Text(contact.initials)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(.secondaryLabel))
                    }
                }
                
                // Name and email
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(contact.givenName) \(contact.familyName)")
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    if let email = contact.emailAddresses.first?.value as String? {
                        Text(email)
                            .font(.system(size: 13))
                            .foregroundColor(Color(.secondaryLabel))
                            .lineLimit(1)
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(Color(.systemBackground))
    }
}

extension CNContact {
    var initials: String {
        let first = String(givenName.prefix(1))
        let last = String(familyName.prefix(1))
        return (first + last).uppercased()
    }
}