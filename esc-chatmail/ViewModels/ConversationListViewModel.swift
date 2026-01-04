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
/// Composes specialized services for search, selection, and filtering
@MainActor
final class ConversationListViewModel: ObservableObject {
    // MARK: - Composed Services

    let searchService: ConversationSearchService
    let selectionService: ConversationSelectionService
    let filterService: ConversationFilterService

    // MARK: - Published State (Presentation)

    @Published var showingComposer = false
    @Published var showingSettings = false

    // MARK: - Dependencies

    let messageActions: MessageActions
    let syncEngine: SyncEngine
    let contactsService: ContactsService

    private let coreDataStack: CoreDataStack
    private let authSession: AuthSession
    private let personCache: PersonCache
    private var syncTimer: Timer?
    private var hasPerformedInitialSync = false
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    /// Primary initializer using Dependencies container
    init(deps: Dependencies? = nil) {
        let dependencies = deps ?? .shared
        self.coreDataStack = dependencies.coreDataStack
        self.syncEngine = dependencies.syncEngine
        self.authSession = dependencies.authSession
        self.personCache = dependencies.personCache
        self.messageActions = dependencies.makeMessageActions()
        self.contactsService = dependencies.makeContactsService()

        // Initialize composed services
        self.searchService = ConversationSearchService()
        self.selectionService = ConversationSelectionService(
            messageActions: dependencies.makeMessageActions(),
            coreDataStack: dependencies.coreDataStack
        )
        self.filterService = ConversationFilterService(
            contactsService: dependencies.makeContactsService()
        )

        // Forward objectWillChange from child services
        searchService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        selectionService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        filterService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    deinit {
        syncTimer?.invalidate()
    }

    // MARK: - Convenience Accessors (View Compatibility)

    /// Binding for search text input
    var searchText: String {
        get { searchService.searchText }
        set { searchService.searchText = newValue }
    }

    /// Current filter selection
    var currentFilter: ConversationFilter {
        get { filterService.currentFilter }
        set { filterService.currentFilter = newValue }
    }

    /// Whether selection mode is active
    var isSelecting: Bool {
        get { selectionService.isSelecting }
        set { selectionService.isSelecting = newValue }
    }

    /// Set of selected conversation IDs
    var selectedConversationIDs: Set<NSManagedObjectID> {
        get { selectionService.selectedConversationIDs }
        set { selectionService.selectedConversationIDs = newValue }
    }

    /// Cached contact emails for filtering
    var contactEmailsCache: Set<String> {
        filterService.contactEmailsCache
    }

    // MARK: - Sync Operations

    func performInitialSync() {
        guard !hasPerformedInitialSync else { return }
        guard authSession.isAuthenticated else {
            Log.info("Skipping initial sync - not authenticated", category: .sync)
            return
        }

        hasPerformedInitialSync = true

        Task {
            do {
                try await syncEngine.performIncrementalSync()
            } catch {
                Log.error("Initial sync error", category: .sync, error: error)
            }
        }
    }

    func performSync() async {
        do {
            try await syncEngine.performIncrementalSync()
        } catch {
            Log.error("Sync error", category: .sync, error: error)
        }
    }

    func startPeriodicSync() {
        stopPeriodicSync()

        syncTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if !self.syncEngine.isSyncing {
                    Log.debug("Performing periodic sync", category: .sync)
                    do {
                        try await self.syncEngine.performIncrementalSync()
                    } catch {
                        Log.error("Periodic sync error", category: .sync, error: error)
                    }
                }
            }
        }
    }

    func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    // MARK: - Selection Operations (Delegate to Service)

    func toggleSelection(for conversation: Conversation) {
        selectionService.toggleSelection(for: conversation)
    }

    func selectAll(from conversations: [Conversation]) {
        selectionService.selectAll(from: conversations)
    }

    func cancelSelection() {
        selectionService.cancelSelection()
    }

    func toggleSelectionMode() {
        selectionService.toggleSelectionMode()
    }

    // MARK: - Conversation Actions

    func archiveConversation(_ conversation: Conversation) {
        Task {
            await messageActions.archiveConversation(conversation: conversation)
        }
    }

    func toggleConversationReadState(_ conversation: Conversation) {
        Task {
            if conversation.inboxUnreadCount > 0 {
                await messageActions.markConversationAsRead(conversation: conversation)
            } else {
                await messageActions.markConversationAsUnread(conversation: conversation)
            }
        }
    }

    func archiveSelectedConversations() {
        selectionService.archiveSelectedConversations()
    }

    // MARK: - Filtering (Delegate to Service)

    func filteredConversations(from conversations: [Conversation]) -> [Conversation] {
        filterService.filteredConversations(
            from: conversations,
            searchText: searchService.debouncedSearchText
        )
    }

    func invalidateFilterCache() {
        filterService.invalidateFilterCache()
    }

    func isConversationWithContact(_ conversation: Conversation) -> Bool {
        filterService.isConversationWithContact(conversation)
    }

    // MARK: - Data Loading

    func prefetchPersonData(from conversations: [Conversation]) {
        let personCache = self.personCache
        Task {
            let allEmails = conversations.prefix(30).flatMap { conversation -> [String] in
                guard let participants = conversation.participants else { return [] }
                return participants.compactMap { $0.person?.email }
            }
            await personCache.prefetch(emails: Array(Set(allEmails)))
        }
    }

    func loadContactsCache() {
        filterService.loadContactsCache()
    }

    func refreshConversationNames() {
        // V2: Fix single-participant names to use full name instead of first name only
        let hasRefreshedKey = "hasRefreshedConversationNamesV2"
        guard !UserDefaults.standard.bool(forKey: hasRefreshedKey) else { return }

        Task {
            let conversationManager = ConversationManager()
            await conversationManager.updateAllConversationRollups(in: coreDataStack.viewContext)
            UserDefaults.standard.set(true, forKey: hasRefreshedKey)
            Log.info("Refreshed all conversation names (V2: full names for single participants)", category: .conversation)
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
        searchService.cleanup()
    }
}
