import Foundation
import CoreData
import Contacts
import Combine

/// Service for filtering conversations by type (contacts/other) and managing contact cache
@MainActor
final class ConversationFilterService: ObservableObject {
    // MARK: - Published State

    @Published var currentFilter: ConversationFilter = .all {
        didSet {
            guard currentFilter != oldValue else { return }
            onFilterStateChange?()
        }
    }
    @Published private(set) var contactEmailsCache: Set<String> = [] {
        didSet {
            guard contactEmailsCache != oldValue else { return }
            onFilterStateChange?()
        }
    }

    // MARK: - Dependencies

    private let contactsService: ContactsService

    // MARK: - Private State

    private var contactsLoadTask: Task<Void, Never>?
    private var contactStoreDidChangeObserver: NSObjectProtocol?
    var onFilterStateChange: (() -> Void)?

    // MARK: - Initialization

    init(contactsService: ContactsService) {
        self.contactsService = contactsService

        // Keep contact-based filtering fresh when the user edits contacts (in-app or via system UI).
        contactStoreDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.loadContactsCache()
            }
        }
    }

    deinit {
        if let observer = contactStoreDidChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Filtering

    /// Filters conversations based on search text and current filter
    func filteredConversations(
        from conversations: [Conversation],
        searchText: String
    ) -> [Conversation] {
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

        return result
    }

    /// Checks if a conversation includes a participant from the user's contacts
    func isConversationWithContact(_ conversation: Conversation) -> Bool {
        guard let participants = conversation.participants else { return false }

        for participant in participants {
            if let email = participant.person?.email {
                if contactEmailsCache.contains(EmailNormalizer.normalize(email)) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Contact Cache Loading

    /// Loads all contact emails into cache for filtering
    func loadContactsCache() {
        contactsLoadTask?.cancel()
        contactsLoadTask = Task.detached { [contactsService, weak self] in
            let authStatus = await MainActor.run { contactsService.authorizationStatus }
            let hasAccess: Bool = {
                if authStatus == .authorized { return true }
                if #available(iOS 18.0, *), authStatus == .limited { return true }
                return false
            }()

            if !hasAccess {
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
                        emails.insert(EmailNormalizer.normalize(emailAddress.value as String))
                    }
                }
                let finalEmails = emails
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.contactEmailsCache = finalEmails
                }
            } catch {
                Log.error("Failed to load contacts", category: .general, error: error)
            }
        }
    }

    /// Cancels any pending tasks
    func cancelTasks() {
        contactsLoadTask?.cancel()
        contactsLoadTask = nil
    }
}
