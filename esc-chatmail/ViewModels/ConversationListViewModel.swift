import Foundation
import CoreData
import Contacts
import Combine

/// Filter options for the conversation list
enum ConversationFilter: String, CaseIterable {
    case all = "All"
    case contacts = "Contacts"
    case other = "Other"

    var icon: String {
        switch self {
        case .all: return "line.3.horizontal.decrease"
        case .contacts: return "person.crop.circle"
        case .other: return "person.crop.circle.badge.questionmark"
        }
    }
}

/// ViewModel for ConversationListView - manages list state and operations
@MainActor
final class ConversationListViewModel: ObservableObject {
    // MARK: - Published State

    @Published var searchText = "" {
        didSet {
            // Debounce search input to avoid re-filtering on every keystroke
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000) // 150ms debounce
                self?.debouncedSearchText = self?.searchText ?? ""
            }
        }
    }
    @Published private(set) var debouncedSearchText = ""
    @Published var currentFilter: ConversationFilter = .all
    @Published var isSelecting = false
    @Published var selectedConversationIDs: Set<NSManagedObjectID> = []
    @Published var showingComposer = false
    @Published var showingSettings = false
    @Published private(set) var contactEmailsCache: Set<String> = []

    // MARK: - Dependencies

    let messageActions: MessageActions
    let syncEngine: SyncEngine
    let contactsService: ContactsService

    private let coreDataStack: CoreDataStack
    private var syncTimer: Timer?
    private var hasPerformedInitialSync = false
    private var searchDebounceTask: Task<Void, Never>?

    /// Cache for filtered results - invalidated when filter/search changes
    private var filteredCache: FilteredConversationsCache?

    // MARK: - Initialization

    init() {
        self.coreDataStack = .shared
        self.syncEngine = .shared
        self.messageActions = MessageActions()
        self.contactsService = ContactsService()
    }

    deinit {
        syncTimer?.invalidate()
    }

    // MARK: - Sync Operations

    func performInitialSync() {
        guard !hasPerformedInitialSync else { return }
        guard AuthSession.shared.isAuthenticated else {
            print("Skipping initial sync - not authenticated")
            return
        }

        hasPerformedInitialSync = true

        Task {
            do {
                try await syncEngine.performIncrementalSync()
            } catch {
                print("Initial sync error: \(error)")
            }
        }
    }

    func performSync() async {
        do {
            try await syncEngine.performIncrementalSync()
        } catch {
            print("Sync error: \(error)")
        }
    }

    func startPeriodicSync() {
        stopPeriodicSync()

        syncTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if !self.syncEngine.isSyncing {
                    print("Performing periodic sync at \(Date())")
                    do {
                        try await self.syncEngine.performIncrementalSync()
                    } catch {
                        print("Periodic sync error: \(error)")
                    }
                }
            }
        }
    }

    func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    // MARK: - Selection Operations

    func toggleSelection(for conversation: Conversation) {
        if selectedConversationIDs.contains(conversation.objectID) {
            selectedConversationIDs.remove(conversation.objectID)
        } else {
            selectedConversationIDs.insert(conversation.objectID)
        }
    }

    func selectAll(from conversations: [Conversation]) {
        if selectedConversationIDs.count == conversations.count {
            selectedConversationIDs.removeAll()
        } else {
            selectedConversationIDs = Set(conversations.map { $0.objectID })
        }
    }

    func cancelSelection() {
        isSelecting = false
        selectedConversationIDs.removeAll()
    }

    func toggleSelectionMode() {
        isSelecting.toggle()
        if !isSelecting {
            selectedConversationIDs.removeAll()
        }
    }

    // MARK: - Conversation Actions

    func archiveConversation(_ conversation: Conversation) {
        Task {
            await messageActions.archiveConversation(conversation: conversation)
            conversation.hidden = true
            coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)
        }
    }

    func archiveSelectedConversations() {
        let context = coreDataStack.viewContext
        let conversationsToArchive = selectedConversationIDs.compactMap { objectID in
            try? context.existingObject(with: objectID) as? Conversation
        }

        let count = conversationsToArchive.count
        print("[ARCHIVE] Starting batch archive of \(count) conversations from \(selectedConversationIDs.count) selected IDs")
        for (index, conv) in conversationsToArchive.enumerated() {
            let messageCount = conv.messages?.count ?? 0
            print("[ARCHIVE] [\(index + 1)/\(count)] '\(conv.displayName ?? "unknown")' (id: \(conv.id), messages: \(messageCount))")
        }

        selectedConversationIDs.removeAll()
        isSelecting = false

        Task {
            for (index, conversation) in conversationsToArchive.enumerated() {
                print("[ARCHIVE] [\(index + 1)/\(count)] Processing '\(conversation.displayName ?? "unknown")'...")
                await messageActions.archiveConversation(conversation: conversation)
                conversation.hidden = true
                print("[ARCHIVE] [\(index + 1)/\(count)] Set hidden=true for '\(conversation.displayName ?? "unknown")'")
            }
            coreDataStack.saveIfNeeded(context: context)
            print("[ARCHIVE] Batch archive complete - saved \(count) conversations")
        }
    }


    // MARK: - Filtering

    func filteredConversations(from conversations: [Conversation]) -> [Conversation] {
        // Use debounced search text for filtering
        let searchQuery = debouncedSearchText

        // Check cache validity
        if let cache = filteredCache,
           cache.isValid(for: conversations, searchText: searchQuery, filter: currentFilter) {
            return cache.results
        }

        var result = conversations

        if !searchQuery.isEmpty {
            let lowercasedQuery = searchQuery.lowercased()
            result = result.filter { conversation in
                conversation.displayName?.lowercased().contains(lowercasedQuery) ?? false ||
                conversation.snippet?.lowercased().contains(lowercasedQuery) ?? false
            }
        }

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
            searchText: searchQuery,
            filter: currentFilter,
            results: result
        )

        return result
    }

    /// Invalidates the filtered cache - call when underlying data changes
    func invalidateFilterCache() {
        filteredCache = nil
    }

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

    // MARK: - Data Loading

    func prefetchPersonData(from conversations: [Conversation]) {
        Task {
            let allEmails = conversations.prefix(30).flatMap { conversation -> [String] in
                guard let participants = conversation.participants else { return [] }
                return participants.compactMap { $0.person?.email }
            }
            await PersonCache.shared.prefetch(emails: Array(Set(allEmails)))
        }
    }

    func loadContactsCache() {
        Task.detached { [contactsService] in
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
                print("Failed to load contacts: \(error)")
            }
        }
    }

    func refreshConversationNames() {
        let hasRefreshedKey = "hasRefreshedConversationNamesV1"
        guard !UserDefaults.standard.bool(forKey: hasRefreshedKey) else { return }

        Task {
            let conversationManager = ConversationManager()
            await conversationManager.updateAllConversationRollups(in: coreDataStack.viewContext)
            UserDefaults.standard.set(true, forKey: hasRefreshedKey)
            print("Refreshed all conversation names to new format")
        }
    }

    /// Called when view appears - performs initial setup
    func onAppear(conversations: [Conversation]) {
        performInitialSync()
        startPeriodicSync()

        // Defer non-critical work to avoid blocking initial render
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.prefetchPersonData(from: conversations)
                self.loadContactsCache()
                self.refreshConversationNames()
            }
        }
    }

    /// Called when view disappears
    func onDisappear() {
        stopPeriodicSync()
        searchDebounceTask?.cancel()
    }
}

// MARK: - Filtered Conversations Cache

/// Caches filtered conversation results to avoid re-filtering on every render
private struct FilteredConversationsCache {
    let sourceCount: Int
    let searchText: String
    let filter: ConversationFilter
    let results: [Conversation]

    /// Checks if cache is still valid for the given parameters
    func isValid(for conversations: [Conversation], searchText: String, filter: ConversationFilter) -> Bool {
        return self.sourceCount == conversations.count &&
               self.searchText == searchText &&
               self.filter == filter
    }
}
