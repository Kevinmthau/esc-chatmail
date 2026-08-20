import Foundation
import CoreData
import Contacts
import Combine

/// Service for filtering conversations by type (contacts/other) and managing contact cache
@MainActor
final class ConversationFilterService: ObservableObject {
    typealias ContactEmailLoader = (Bool) async -> Set<String>?

    // MARK: - Published State

    @Published var currentFilter: ConversationFilter = .all {
        didSet {
            guard currentFilter != oldValue else { return }
            if currentFilter.requiresContactCache && !hasLoadedContactsCache && !isLoadingContactsCache {
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
    private let notificationCenter: NotificationCenter
    private let contactEmailLoader: ContactEmailLoader

    // MARK: - Private State

    private var contactsLoadTask: Task<Void, Never>?
    private var contactStoreDidChangeObserver: NSObjectProtocol?
    private var isLoadingContactsCache = false
    private var hasLoadedContactsCache = false
    private var pendingContactsCacheInvalidation = false
    var onFilterStateChange: (() -> Void)?

    // MARK: - Initialization

    init(
        contactsService: ContactsService,
        notificationCenter: NotificationCenter = .default,
        contactEmailLoader: ContactEmailLoader? = nil
    ) {
        self.contactsService = contactsService
        self.notificationCenter = notificationCenter
        self.contactEmailLoader = contactEmailLoader ?? {
            await Self.loadContactEmails(
                contactsService: contactsService,
                requestAccessIfNeeded: $0
            )
        }

        // Keep contact-based filtering fresh when the user edits contacts (in-app or via system UI).
        contactStoreDidChangeObserver = notificationCenter.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleContactStoreDidChange()
            }
        }
    }

    deinit {
        if let observer = contactStoreDidChangeObserver {
            notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Filtering

    /// Returns true when the conversation should be visible for the current filter state.
    func matches(_ conversation: Conversation, searchText: String) -> Bool {
        matchesSearch(conversation, searchText: searchText) &&
        matchesCurrentFilter(conversation)
    }

    /// Checks if a conversation includes a participant from the user's contacts
    private func isConversationWithContact(_ conversation: Conversation) -> Bool {
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
        contactsLoadTask = Task { [weak self] in
            guard let self else { return }

            let loadedEmails = await self.contactEmailLoader(requestAccessIfNeeded)
            guard !Task.isCancelled else { return }

            self.finishContactsLoad(with: loadedEmails)
        }
    }

    /// Cancels any pending tasks
    func cancelTasks() {
        contactsLoadTask?.cancel()
        contactsLoadTask = nil
        isLoadingContactsCache = false
        pendingContactsCacheInvalidation = false
    }

    private func matchesSearch(_ conversation: Conversation, searchText: String) -> Bool {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchText.isEmpty else { return true }

        let comparisonOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return conversation.displayName?.range(
            of: trimmedSearchText,
            options: comparisonOptions
        ) != nil || conversation.snippet?.range(
            of: trimmedSearchText,
            options: comparisonOptions
        ) != nil
    }

    private func matchesCurrentFilter(_ conversation: Conversation) -> Bool {
        switch currentFilter {
        case .all:
            return true
        case .unread:
            return conversation.inboxUnreadCount > 0
        case .contacts:
            return isConversationWithContact(conversation)
        case .other:
            return !isConversationWithContact(conversation)
        }
    }

    private func handleContactStoreDidChange() {
        hasLoadedContactsCache = false

        guard !isLoadingContactsCache else {
            pendingContactsCacheInvalidation = true
            return
        }

        loadContactsCache()
    }

    private func finishContactsLoad(with loadedEmails: Set<String>?) {
        isLoadingContactsCache = false
        contactsLoadTask = nil

        if pendingContactsCacheInvalidation {
            pendingContactsCacheInvalidation = false
            loadContactsCache()
            return
        }

        guard let loadedEmails else { return }

        contactEmailsCache = loadedEmails
        hasLoadedContactsCache = true
    }

    private static func loadContactEmails(
        contactsService: ContactsService,
        requestAccessIfNeeded: Bool
    ) async -> Set<String>? {
        let authStatus = await MainActor.run { contactsService.authorizationStatus }
        let hasAccess: Bool = {
            if authStatus == .authorized { return true }
            if #available(iOS 18.0, *), authStatus == .limited { return true }
            return false
        }()

        if !hasAccess {
            guard requestAccessIfNeeded, authStatus == .notDetermined else { return nil }
            let granted = await contactsService.requestAccess()
            if !granted { return nil }
        }

        return await Task.detached(priority: .userInitiated) {
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
                return emails
            } catch {
                Log.error("Failed to load contacts", category: .general, error: error)
                return nil
            }
        }.value
    }
}

private extension ConversationFilter {
    var requiresContactCache: Bool {
        switch self {
        case .contacts, .other:
            return true
        case .all, .unread:
            return false
        }
    }
}
