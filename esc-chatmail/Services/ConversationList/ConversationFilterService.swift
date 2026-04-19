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
            if currentFilter != .all && !hasLoadedContactsCache && !isLoadingContactsCache {
                loadContactsCache(requestAccessIfNeeded: true)
            }
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
    private var isLoadingContactsCache = false
    private var hasLoadedContactsCache = false
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
        conversations.filter { matches($0, searchText: searchText) }
    }

    /// Returns true when the conversation should be visible for the current filter state.
    func matches(_ conversation: Conversation, searchText: String) -> Bool {
        matchesSearch(conversation, searchText: searchText) &&
        matchesCurrentFilter(conversation)
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
    func loadContactsCache(requestAccessIfNeeded: Bool = false) {
        guard !isLoadingContactsCache else { return }

        isLoadingContactsCache = true
        contactsLoadTask = Task.detached { [contactsService, weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.isLoadingContactsCache = false
                    self?.contactsLoadTask = nil
                }
            }

            let authStatus = await MainActor.run { contactsService.authorizationStatus }
            let hasAccess: Bool = {
                if authStatus == .authorized { return true }
                if #available(iOS 18.0, *), authStatus == .limited { return true }
                return false
            }()

            if !hasAccess {
                guard requestAccessIfNeeded, authStatus == .notDetermined else { return }
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
                    self.hasLoadedContactsCache = true
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
        isLoadingContactsCache = false
    }

    private func matchesSearch(_ conversation: Conversation, searchText: String) -> Bool {
        guard !searchText.isEmpty else { return true }

        let lowercasedQuery = searchText.lowercased()
        return conversation.displayName?.lowercased().contains(lowercasedQuery) ?? false ||
            conversation.snippet?.lowercased().contains(lowercasedQuery) ?? false
    }

    private func matchesCurrentFilter(_ conversation: Conversation) -> Bool {
        switch currentFilter {
        case .all:
            return true
        case .contacts:
            return isConversationWithContact(conversation)
        case .other:
            return !isConversationWithContact(conversation)
        }
    }
}
