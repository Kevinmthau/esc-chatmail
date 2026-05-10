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
    static let conversationNameRefreshMigrationKey = "hasRefreshedConversationNamesV4"

    // MARK: - Composed Services

    let searchService: ConversationSearchService
    let selectionService: ConversationSelectionService
    let filterService: ConversationFilterService

    // MARK: - Published State (Presentation)

    @Published var showingComposer = false
    @Published var showingSettings = false
    @Published private(set) var filteredConversationItems: [ConversationListItem] = []

    // MARK: - Dependencies

    let messageActions: MessageActions
    let syncEngine: SyncEngine
    let foregroundSyncCoordinator: ForegroundSyncCoordinator
    let conversationManager: ConversationManager

    private let storage: StorageDependencies
    private var cancellables = Set<AnyCancellable>()
    private var conversationChangesCancellable: AnyCancellable?
    private let taskManager = ViewModelTaskManager()
    private var listStore = ConversationListStore()
    private weak var observedConversationContext: NSManagedObjectContext?

    // MARK: - Initialization

    /// Primary initializer using the narrowed conversation-list bundle.
    init(
        dependencies: ConversationListDependencies? = nil,
        searchService: ConversationSearchService? = nil,
        selectionService: ConversationSelectionService? = nil,
        filterService: ConversationFilterService? = nil
    ) {
        let resolvedDependencies = dependencies ?? Dependencies.shared.makeConversationListDependencies()
        self.storage = resolvedDependencies.storage
        self.syncEngine = resolvedDependencies.syncEngine
        self.foregroundSyncCoordinator = resolvedDependencies.foregroundSyncCoordinator
        self.messageActions = resolvedDependencies.messaging.makeMessageActions()
        self.conversationManager = resolvedDependencies.conversationManager

        // Initialize composed services
        let resolvedSearchService = searchService ?? resolvedDependencies.makeConversationSearchService()
        let resolvedSelectionService = selectionService ?? resolvedDependencies.makeConversationSelectionService()
        let resolvedFilterService = filterService ?? resolvedDependencies.makeConversationFilterService()
        self.searchService = resolvedSearchService
        self.selectionService = resolvedSelectionService
        self.filterService = resolvedFilterService

        // Forward objectWillChange from child services
        forwardChanges(from: resolvedSearchService, storing: &cancellables)
        forwardChanges(from: resolvedSelectionService, storing: &cancellables)
        forwardChanges(from: resolvedFilterService, storing: &cancellables)

        bindFiltering()
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

    var filteredConversations: [Conversation] {
        filteredConversationItems.compactMap { listStore.conversation(for: $0.id) }
    }

    /// Cached contact emails for filtering
    var contactEmailsCache: Set<String> {
        filterService.contactEmailsCache
    }

    // MARK: - Sync Operations

    func performSync() async {
        await foregroundSyncCoordinator.performUserInitiatedSync(reason: "pullToRefresh")
    }

    // MARK: - Selection Operations (Delegate to Service)

    func toggleSelection(for conversation: Conversation) {
        selectionService.toggleSelection(for: conversation)
    }

    func toggleSelection(for objectID: NSManagedObjectID) {
        selectionService.toggleSelection(for: objectID)
    }

    func selectAll(from conversations: [Conversation]) {
        selectionService.selectAll(from: conversations)
    }

    func selectAllVisibleConversations() {
        selectionService.selectAll(conversationIDs: filteredConversationItems.map(\.id))
    }

    func cancelSelection() {
        selectionService.cancelSelection()
    }

    func toggleSelectionMode() {
        selectionService.toggleSelectionMode()
    }

    // MARK: - Conversation Actions

    func archiveConversation(_ conversation: Conversation) {
        archiveConversation(withID: conversation.objectID)
    }

    func archiveConversation(withID objectID: NSManagedObjectID) {
        guard let conversation = listStore.conversation(for: objectID) ??
                (try? conversationContext.existingObject(with: objectID) as? Conversation) else {
            return
        }

        let convID = conversation.objectID
        taskManager.run("archive-\(convID)") { [weak self] in
            guard let self = self else { return }
            await messageActions.archiveConversation(conversation: conversation)
        }
    }

    func toggleConversationReadState(_ conversation: Conversation) {
        toggleConversationReadState(withID: conversation.objectID)
    }

    func toggleConversationReadState(withID objectID: NSManagedObjectID) {
        guard let conversation = listStore.conversation(for: objectID) ??
                (try? conversationContext.existingObject(with: objectID) as? Conversation) else {
            return
        }

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

    func refreshConversations(_ conversations: [Conversation]) {
        listStore.replaceAll(with: conversations, matchesVisibility: matchesVisibleConversation(_:))
        publishVisibleItems()
    }

    func applyConversationChanges(
        updatedConversations: [Conversation] = [],
        deletedIDs: Set<NSManagedObjectID> = []
    ) {
        guard !updatedConversations.isEmpty || !deletedIDs.isEmpty else { return }

        let removedIDs = listStore.applyChanges(
            updatedConversations: updatedConversations,
            deletedIDs: deletedIDs,
            isSourceConversation: isSourceConversation(_:),
            matchesVisibility: matchesVisibleConversation(_:)
        )

        if !removedIDs.isEmpty {
            selectionService.selectedConversationIDs.subtract(removedIDs)
        }

        publishVisibleItems()
    }

    func isConversationWithContact(_ conversation: Conversation) -> Bool {
        filterService.isConversationWithContact(conversation)
    }

    // MARK: - Data Loading

    func prefetchPersonData(from conversations: [Conversation]) {
        let personCache = storage.personCache
        let profilePhotoResolver = storage.profilePhotoResolver

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
            await profilePhotoResolver.prefetchPhotos(for: uniqueEmails)
        }
    }

    func loadContactsCache(requestAccessIfNeeded: Bool = false) {
        filterService.loadContactsCache(requestAccessIfNeeded: requestAccessIfNeeded)
    }

    func refreshConversationNames() {
        // V4: refresh stored conversation display names only. Rollup metadata stays sync-owned.
        let hasRefreshedKey = Self.conversationNameRefreshMigrationKey
        guard !UserDefaults.standard.bool(forKey: hasRefreshedKey) else { return }
        guard hasExistingConversationsForNameRefresh() else {
            UserDefaults.standard.set(true, forKey: hasRefreshedKey)
            return
        }

        taskManager.run("refreshNames") { [weak self] in
            guard let self = self else { return }
            let context = storage.makeBackgroundContext()
            await conversationManager.updateAllConversationDisplayNames(in: context)
            guard storage.saveIfNeeded(context) else { return }
            UserDefaults.standard.set(true, forKey: hasRefreshedKey)
            Log.info("Refreshed conversation display names (V4)", category: .conversation)
        }
    }

    /// Called when view appears - performs initial setup
    func onAppear(conversations: [Conversation], in context: NSManagedObjectContext) {
        startObservingConversationChanges(in: context)
        refreshConversations(conversations)

        // Prefetch photos immediately to avoid slow avatar loading in rows
        // This needs to run before rows' .task blocks fire
        prefetchPersonData(from: conversations)

        // Defer non-critical work to avoid blocking initial render
        taskManager.runDetached("deferredSetup") { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.loadContactsCache(requestAccessIfNeeded: false)
                self.refreshConversationNames()
            }
        }
    }

    /// Called when view disappears
    func onDisappear() {
        // Keep observing Core Data changes across transient SwiftUI disappearances
        // caused by sheets and navigation pushes so optimistic send updates are not missed.
        searchService.cleanup()
        selectionService.cancelTasks()
        filterService.cancelTasks()
        taskManager.cancelAll()
    }

    private func bindFiltering() {
        searchService.onDebouncedSearchTextChange = { [weak self] in
            self?.recomputeFilteredConversations()
        }

        filterService.onFilterStateChange = { [weak self] in
            self?.recomputeFilteredConversations()
        }
    }

    private func recomputeFilteredConversations() {
        listStore.recomputeVisibleItems(matchesVisibility: matchesVisibleConversation(_:))
        publishVisibleItems()
    }

    private func publishVisibleItems() {
        let visibleItems = listStore.visibleItems
        guard visibleItems != filteredConversationItems else { return }
        filteredConversationItems = visibleItems
    }

    private var conversationContext: NSManagedObjectContext {
        observedConversationContext ?? storage.viewContext
    }

    private func hasExistingConversationsForNameRefresh() -> Bool {
        let request = Conversation.fetchRequest()
        request.includesPendingChanges = false

        do {
            return try storage.viewContext.count(for: request) > 0
        } catch {
            Log.error("Failed to count conversations for display-name refresh migration", category: .conversation, error: error)
            return false
        }
    }

    private func isSourceConversation(_ conversation: Conversation) -> Bool {
        conversation.archivedAt == nil
    }

    private func matchesVisibleConversation(_ conversation: Conversation) -> Bool {
        filterService.matches(conversation, searchText: searchService.debouncedSearchText)
    }

    private func startObservingConversationChanges(in context: NSManagedObjectContext) {
        guard observedConversationContext !== context || conversationChangesCancellable == nil else {
            return
        }

        conversationChangesCancellable?.cancel()
        observedConversationContext = context
        conversationChangesCancellable = NotificationCenter.default.publisher(
            for: .NSManagedObjectContextObjectsDidChange,
            object: context
        )
        .sink { [weak self] notification in
            self?.handleConversationContextChange(notification)
        }
    }

    private func handleConversationContextChange(_ notification: Notification) {
        guard notification.userInfo?[NSInvalidatedAllObjectsKey] == nil else {
            listStore.removeAll()
            selectionService.selectedConversationIDs.removeAll()
            publishVisibleItems()
            return
        }

        let inserted = conversationObjects(forKey: NSInsertedObjectsKey, in: notification)
        let updated = conversationObjects(forKey: NSUpdatedObjectsKey, in: notification)
        let refreshed = conversationObjects(forKey: NSRefreshedObjectsKey, in: notification)
        let personAffected = conversationsAffectedByPersonChanges(in: notification)
        let invalidatedIDs = conversationObjectIDs(forKey: NSInvalidatedObjectsKey, in: notification)
        let deletedIDs = conversationObjectIDs(forKey: NSDeletedObjectsKey, in: notification)
        let updatedConversations = uniqueConversations(from: inserted + updated + refreshed + personAffected)
        let removedIDs = deletedIDs.union(invalidatedIDs)

        applyConversationChanges(updatedConversations: updatedConversations, deletedIDs: removedIDs)
    }

    private func conversationObjects(forKey key: String, in notification: Notification) -> [Conversation] {
        let objects = notification.userInfo?[key] as? Set<NSManagedObject> ?? []
        return objects.compactMap { $0 as? Conversation }
    }

    private func conversationObjectIDs(forKey key: String, in notification: Notification) -> Set<NSManagedObjectID> {
        let objects = notification.userInfo?[key] as? Set<NSManagedObject> ?? []
        return Set(objects.compactMap { object in
            guard object is Conversation else { return nil }
            return object.objectID
        })
    }

    private func conversationsAffectedByPersonChanges(in notification: Notification) -> [Conversation] {
        contextObjects(
            forKeys: [NSUpdatedObjectsKey, NSRefreshedObjectsKey],
            in: notification
        )
        .compactMap { $0 as? Person }
        .flatMap { person in
            person.conversationParticipations?.compactMap(\.conversation) ?? []
        }
    }

    private func contextObjects(
        forKeys keys: [String],
        in notification: Notification
    ) -> Set<NSManagedObject> {
        keys.reduce(into: Set<NSManagedObject>()) { result, key in
            let objects = notification.userInfo?[key] as? Set<NSManagedObject> ?? []
            result.formUnion(objects)
        }
    }

    private func uniqueConversations(from conversations: [Conversation]) -> [Conversation] {
        var uniqueByID: [NSManagedObjectID: Conversation] = [:]

        for conversation in conversations {
            uniqueByID[conversation.objectID] = conversation
        }

        return Array(uniqueByID.values)
    }
}
