import Foundation
import Combine

/// Handles contact searching, autocomplete UI state, and access permissions
@MainActor
final class ContactAutocompleteService: ObservableObject {
    @Published var autocompleteContacts: [ContactsService.ContactMatch] = []
    @Published var showAutocomplete = false

    private let contactsService: ContactsService
    private var searchTask: Task<Void, Never>?
    private let searchDebounceInterval: UInt64 = 150_000_000 // 150ms in nanoseconds

    init(contactsService: ContactsService = ContactsService( )) {
        self.contactsService = contactsService
    }

    func requestAccess() async {
        if contactsService.authorizationStatus == .notDetermined {
            _ = await contactsService.requestAccess()
        }
    }

    func searchContacts(query: String) {
        // Cancel any pending search
        searchTask?.cancel()

        guard !query.isEmpty else {
            clearAutocomplete()
            return
        }

        // Debounce: wait before searching
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: searchDebounceInterval)
            } catch {
                return // Task was cancelled
            }

            guard !Task.isCancelled else { return }

            let matches = await contactsService.searchContacts(query: query)

            guard !Task.isCancelled else { return }

            autocompleteContacts = matches
            showAutocomplete = !matches.isEmpty
        }
    }

    func selectContact(_ contact: ContactsService.ContactMatch, email: String? = nil) -> (email: String, displayName: String) {
        let selectedEmail = email ?? contact.primaryEmail
        clearAutocomplete()
        return (selectedEmail, contact.displayName)
    }

    func clearAutocomplete() {
        searchTask?.cancel()
        autocompleteContacts = []
        showAutocomplete = false
    }
}
