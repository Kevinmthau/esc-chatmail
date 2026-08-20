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

    /// Designated initializer: the service depends only on a loader closure,
    /// so tests inject one directly without building a throwaway
    /// `ContactsService`.
    init(
        contactEmailLoader: @escaping ContactEmailLoader,
        notificationCenter: NotificationCenter = .default
    ) {
        self.notificationCenter = notificationCenter
        self.contactEmailLoader = contactEmailLoader

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

    /// Production convenience: sources the contact-email cache from
    /// `ContactsService.allContactEmails`, which owns the Contacts-domain
    /// access check and store enumeration.
    convenience init(
        contactsService: ContactsService,
        notificationCenter: NotificationCenter = .default
    ) {
        self.init(
            contactEmailLoader: {
                await contactsService.allContactEmails(requestAccessIfNeeded: $0)
            },
            notificationCenter: notificationCenter
        )
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
        // Skip when the cache is already loaded and this call would not request
        // access: every list onAppear re-enumerated the whole address book for
        // an identical result. CNContactStoreDidChange already resets
        // hasLoadedContactsCache, so contact edits still trigger a reload.
        guard !isLoadingContactsCache, !(hasLoadedContactsCache && !requestAccessIfNeeded) else { return }

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
}
