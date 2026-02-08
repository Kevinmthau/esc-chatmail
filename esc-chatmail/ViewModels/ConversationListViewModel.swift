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
    private var lastSyncTriggerAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private let taskManager = ViewModelTaskManager()
    private let periodicSyncInterval: TimeInterval = 120
    private let minimumPeriodicSyncGap: TimeInterval = 90

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
        forwardChanges(from: searchService, storing: &cancellables)
        forwardChanges(from: selectionService, storing: &cancellables)
        forwardChanges(from: filterService, storing: &cancellables)
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

        taskManager.run("initialSync", priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            markSyncTriggered()
            do {
                try await syncEngine.performIncrementalSync()
            } catch {
                Log.error("Initial sync error", category: .sync, error: error)
            }
        }
    }

    func performSync() async {
        markSyncTriggered()
        do {
            try await syncEngine.performIncrementalSync()
        } catch {
            Log.error("Sync error", category: .sync, error: error)
        }
    }

    func startPeriodicSync() {
        stopPeriodicSync()

        syncTimer = Timer.scheduledTimer(withTimeInterval: periodicSyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.taskManager.run("periodicSync") { [weak self] in
                    guard let self = self, !self.syncEngine.isSyncing else { return }
                    guard self.shouldTriggerSync(minInterval: self.minimumPeriodicSyncGap) else {
                        Log.debug("Skipping periodic sync (throttled)", category: .sync)
                        return
                    }
                    self.markSyncTriggered()
                    Log.debug("Performing periodic sync", category: .sync)
                    do {
                        try await self.syncEngine.performIncrementalSync()
                    } catch {
                        Log.error("Periodic sync error", category: .sync, error: error)
                    }
                }
            }
        }
        syncTimer?.tolerance = 15
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
        let convID = conversation.objectID
        taskManager.run("archive-\(convID)") { [weak self] in
            guard let self = self else { return }
            await messageActions.archiveConversation(conversation: conversation)
        }
    }

    func toggleConversationReadState(_ conversation: Conversation) {
        let convID = conversation.objectID
        taskManager.run("toggleRead-\(convID)") { [weak self] in
            guard let self = self else { return }
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

    func reportSpamSelectedConversations() {
        selectionService.reportSpamSelectedConversations()
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

        // Extract emails on MainActor before entering detached task
        // (NSManagedObjects are not Sendable)
        let config = VirtualScrollConfiguration.default
        let prefetchCount = config.visibleItemCount + config.bufferSize  // 30

        let allEmails = conversations.prefix(prefetchCount).flatMap { conversation -> [String] in
            guard let participants = conversation.participants else { return [] }
            return participants.compactMap { $0.person?.email }
        }
        let uniqueEmails = Array(Set(allEmails))

        taskManager.runDetached("prefetchPersonData") {
            await personCache.prefetch(emails: uniqueEmails)

            // Also prefetch profile photos to avoid thundering herd on first load
            await ProfilePhotoResolver.shared.prefetchPhotos(for: uniqueEmails)
        }
    }

    func loadContactsCache() {
        filterService.loadContactsCache()
    }

    func refreshConversationNames() {
        // V2: Fix single-participant names to use full name instead of first name only
        let hasRefreshedKey = "hasRefreshedConversationNamesV2"
        guard !UserDefaults.standard.bool(forKey: hasRefreshedKey) else { return }

        taskManager.run("refreshNames") { [weak self] in
            guard let self = self else { return }
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

        // Prefetch photos immediately to avoid slow avatar loading in rows
        // This needs to run before rows' .task blocks fire
        prefetchPersonData(from: conversations)

        // Defer non-critical work to avoid blocking initial render
        taskManager.runDetached("deferredSetup") { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.loadContactsCache()
                self.refreshConversationNames()
            }
        }
    }

    /// Called when view disappears
    func onDisappear() {
        stopPeriodicSync()
        searchService.cleanup()
        taskManager.cancelAll()
    }

    private func shouldTriggerSync(minInterval: TimeInterval) -> Bool {
        guard let lastSyncTriggerAt else { return true }
        return Date().timeIntervalSince(lastSyncTriggerAt) >= minInterval
    }

    private func markSyncTriggered() {
        lastSyncTriggerAt = Date()
    }
}
