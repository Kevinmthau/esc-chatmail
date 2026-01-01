import Foundation
import CoreData
import Contacts
import Combine

/// Service for filtering conversations by type (contacts/other) and managing contact cache
@MainActor
final class ConversationFilterService: ObservableObject {
    // MARK: - Published State

    @Published var currentFilter: ConversationFilter = .all
    @Published private(set) var contactEmailsCache: Set<String> = []

    // MARK: - Dependencies

    private let contactsService: ContactsService

    // MARK: - Private State

    private var filteredCache: FilteredConversationsCache?

    // MARK: - Initialization

    init(contactsService: ContactsService) {
        self.contactsService = contactsService
    }

    // MARK: - Filtering

    /// Filters conversations based on search text and current filter
    func filteredConversations(
        from conversations: [Conversation],
        searchText: String
    ) -> [Conversation] {
        // Check cache validity
        if let cache = filteredCache,
           cache.isValid(for: conversations, searchText: searchText, filter: currentFilter) {
            return cache.results
        }

        var result = conversations

        // Apply search filter
        if !searchText.isEmpty {
            let lowercasedQuery = searchText.lowercased()
            result = result.filter { conversation in
                conversation.displayName?.lowercased().contains(lowercasedQuery) ?? false ||
                conversation.snippet?.lowercased().contains(lowercasedQuery) ?? false
            }
        }

        // Apply type filter
        switch currentFilter {
        case .all:
            break
        case .contacts:
            result = result.filter { isConversationWithContact($0) }
        case .other:
            result = result.filter { !isConversationWithContact($0) }
        }

        // Update cache
        filteredCache = FilteredConversationsCache(
            sourceCount: conversations.count,
            searchText: searchText,
            filter: currentFilter,
            results: result,
            firstObjectID: conversations.first?.objectID
        )

        return result
    }

    /// Invalidates the filtered cache - call when underlying data changes
    func invalidateFilterCache() {
        filteredCache = nil
    }

    /// Checks if a conversation includes a participant from the user's contacts
    func isConversationWithContact(_ conversation: Conversation) -> Bool {
        guard let participants = conversation.participants else { return false }

        for participant in participants {
            if let email = participant.person?.email {
                if contactEmailsCache.contains(email.lowercased()) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Contact Cache Loading

    /// Loads all contact emails into cache for filtering
    func loadContactsCache() {
        Task.detached { [contactsService, weak self] in
            let authStatus = await MainActor.run { contactsService.authorizationStatus }
            if authStatus != .authorized {
                let granted = await contactsService.requestAccess()
                if !granted { return }
            }

            let contactStore = CNContactStore()
            let keysToFetch = [CNContactEmailAddressesKey as CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keysToFetch)

            do {
                var emails: Set<String> = []
                try contactStore.enumerateContacts(with: request) { contact, _ in
                    for emailAddress in contact.emailAddresses {
                        emails.insert((emailAddress.value as String).lowercased())
                    }
                }
                let finalEmails = emails
                await MainActor.run { [weak self] in
                    self?.contactEmailsCache = finalEmails
                }
            } catch {
                Log.error("Failed to load contacts", category: .general, error: error)
            }
        }
    }
}

// MARK: - Filtered Conversations Cache

/// Caches filtered conversation results to avoid re-filtering on every render
private struct FilteredConversationsCache {
    let sourceCount: Int
    let searchText: String
    let filter: ConversationFilter
    let results: [Conversation]
    let firstObjectID: NSManagedObjectID?

    /// Checks if cache is still valid for the given parameters
    func isValid(for conversations: [Conversation], searchText: String, filter: ConversationFilter) -> Bool {
        return self.sourceCount == conversations.count &&
               self.searchText == searchText &&
               self.filter == filter &&
               self.firstObjectID == conversations.first?.objectID
    }
}
