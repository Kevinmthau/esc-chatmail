import Foundation
import CoreData
import Contacts
import Combine

/// ViewModel for ConversationListView - manages list state and operations
/// Composes specialized services for search, selection, and filtering
///
/// The type is split across multiple files for organization:
/// - `ConversationListViewModel.swift` (this file) - stored state,
///   initialization, service delegation, launch-repair forwarders, lifecycle,
///   window paging, and visibility predicates
/// - `ConversationListViewModel+ChangeObservation.swift` - Core Data
///   change-observation pipeline (subscriptions, change handlers, relevance
///   guards, notification-payload helpers)
@MainActor
final class ConversationListViewModel: ObservableObject {
    /// Alias for `ConversationLaunchRepairCoordinator`'s key, kept so existing
    /// call sites and tests keep addressing the flag through the view model.
    static let conversationNameRefreshMigrationKey =
        ConversationLaunchRepairCoordinator.conversationNameRefreshMigrationKey
    /// Alias for `ConversationLaunchRepairCoordinator`'s key, kept so existing
    /// call sites and tests keep addressing the flag through the view model.
    static let conversationPreviewRepairMigrationKey =
        ConversationLaunchRepairCoordinator.conversationPreviewRepairMigrationKey

    // MARK: - Composed Services

    let searchService: ConversationSearchService
    let selectionService: ConversationSelectionService
    let filterService: ConversationFilterService

    // MARK: - Published State (Presentation)

    @Published private(set) var filteredConversationItems: [ConversationListItem] = []

    // MARK: - Dependencies

    let messageActions: MessageActions
    let foregroundSyncCoordinator: ForegroundSyncCoordinator

    private let storage: StorageDependencies
    private let launchRepairCoordinator: ConversationLaunchRepairCoordinator

    // MARK: - List & Observation State

    private var cancellables = Set<AnyCancellable>()
    /// Subscription to the observed context's objectsDidChange stream. Stored
    /// here because extensions cannot hold storage; internal (not private) so
    /// the `+ChangeObservation` facet, its only user, can manage it.
    var conversationChangesCancellable: AnyCancellable?
    /// Subscription to sibling contexts' didSaveObjectIDs stream. Stored here
    /// because extensions cannot hold storage; internal (not private) so the
    /// `+ChangeObservation` facet, its only user, can manage it.
    var conversationSavesCancellable: AnyCancellable?
    private let taskManager = ViewModelTaskManager()
    /// Internal (not private) so the `+ChangeObservation` facet can clear it
    /// on wholesale invalidation and feed it live changes.
    var listStore = ConversationListStore()
    private let windowProvider: ConversationWindowProvider
    private var loadedConversationLimit: Int
    private var hasLoadedAllConversationWindow = false
    /// Emails already handed to the person/avatar prefetchers for the current
    /// window generation. Reset when the query changes or the store is
    /// invalidated wholesale, so a genuinely fresh window prefetches again.
    /// Internal (not private) so the `+ChangeObservation` facet can perform
    /// that wholesale-invalidation reset.
    var prefetchedPersonEmails: Set<String> = []
    /// Internal (not private) so the `+ChangeObservation` facet, which owns
    /// the subscriptions, can register the observed context and read it back.
    weak var observedConversationContext: NSManagedObjectContext?

    // MARK: - Initialization

    /// Initializes the view model from the narrowed conversation-list bundle.
    /// The composed services come exclusively from the bundle's factories, so
    /// a caller that wants a specific service instance supplies a bundle whose
    /// factory returns it (tests use `ConversationListDependencies.forTesting`).
    init(
        dependencies: ConversationListDependencies? = nil,
        windowProvider: ConversationWindowProvider = ConversationWindowProvider()
    ) {
        let resolvedDependencies = dependencies ?? Dependencies.shared.makeConversationListDependencies()
        self.storage = resolvedDependencies.storage
        self.foregroundSyncCoordinator = resolvedDependencies.foregroundSyncCoordinator
        self.messageActions = resolvedDependencies.messaging.makeMessageActions()
        // Constructed (not injected) here so its `.syncCompleted` re-arm
        // subscription exists from view-model init — the coordinator's own
        // requirement that a sync finishing before first appear still re-arms.
        self.launchRepairCoordinator = ConversationLaunchRepairCoordinator(
            storage: resolvedDependencies.storage,
            conversationManager: resolvedDependencies.conversationManager,
            syncWaiter: resolvedDependencies.syncWaiter,
            notificationCenter: resolvedDependencies.notificationCenter
        )
        self.windowProvider = windowProvider
        self.loadedConversationLimit = windowProvider.initialLimit

        // Initialize composed services
        let resolvedSearchService = resolvedDependencies.makeConversationSearchService()
        let resolvedSelectionService = resolvedDependencies.makeConversationSelectionService()
        let resolvedFilterService = resolvedDependencies.makeConversationFilterService()
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

    // MARK: - Sync Operations

    func performSync() async {
        await foregroundSyncCoordinator.performUserInitiatedSync(reason: "pullToRefresh")
    }

    // MARK: - Selection Operations (Delegate to Service)

    func toggleSelection(for objectID: NSManagedObjectID) {
        selectionService.toggleSelection(for: objectID)
    }

    func selectAllVisibleConversations() {
        selectionService.selectAll(conversationIDs: filteredConversationItems.map(\.id))
    }

    func toggleSelectionMode() {
        selectionService.toggleSelectionMode()
    }

    // MARK: - Conversation Actions

    func archiveConversation(withID objectID: NSManagedObjectID) {
        guard let conversation = conversation(withID: objectID) else {
            return
        }

        let convID = conversation.objectID
        taskManager.run("archive-\(convID)") { [weak self] in
            guard let self = self else { return }
            await messageActions.archiveConversation(conversation: conversation)
        }
    }

    func toggleConversationReadState(withID objectID: NSManagedObjectID) {
        guard let conversation = conversation(withID: objectID) else {
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

    // MARK: - List Store Updates

    func applyConversationChanges(
        updatedConversations: [Conversation] = [],
        deletedIDs: Set<NSManagedObjectID> = []
    ) {
        guard !updatedConversations.isEmpty || !deletedIDs.isEmpty else { return }

        // The removed-ID set is not needed here: rows leaving the window drop
        // out of the selection in publishVisibleItems, which also sees the
        // rows upsertConversation hides without reporting them.
        _ = listStore.applyChanges(
            updatedConversations: updatedConversations,
            deletedIDs: deletedIDs,
            isSourceConversation: isSourceConversation(_:),
            matchesVisibility: matchesVisibleConversation(_:)
        )

        let trimmedIDs = listStore.trimVisibleItems(to: loadedConversationLimit)
        if !trimmedIDs.isEmpty {
            // A non-empty trim proves the store holds rows beyond the window, so
            // paging must reopen even when a short initial fetch latched "all loaded".
            hasLoadedAllConversationWindow = false
        }

        if backfillConversationWindowIfNeeded() {
            return
        }

        publishVisibleItems()
    }

    // MARK: - Prefetching & Contacts

    /// Prefetches display names and avatars for rows newly entering the
    /// window. Submits only the policy's delta — emails not yet handed to
    /// the prefetchers this window generation — and skips the detached task
    /// entirely when the delta is empty, so reloads that add no rows
    /// (pop-back, backfill re-appears) do nothing.
    private func prefetchPersonData(from newItems: [ConversationListItem]) {
        let personCache = storage.personCache
        let profilePhotoResolver = storage.profilePhotoResolver

        let config = VirtualScrollConfiguration.default
        let prefetchCount = config.visibleItemCount + config.bufferSize  // 30
        let emails = ConversationListPrefetchPolicy.emailsToPrefetch(
            newItems: newItems,
            alreadySubmitted: prefetchedPersonEmails,
            limit: prefetchCount
        )
        guard !emails.isEmpty else { return }
        prefetchedPersonEmails.formUnion(emails)

        taskManager.runDetached("prefetchPersonData") {
            await personCache.prefetch(emails: emails)

            // Also prefetch profile photos to avoid thundering herd on first
            // load; submitting only the delta of newly visible rows keeps
            // later reloads from re-herding Contacts for rows already warmed.
            await profilePhotoResolver.prefetchPhotos(for: emails)
        }
    }

    private func loadContactsCache(requestAccessIfNeeded: Bool = false) {
        filterService.loadContactsCache(requestAccessIfNeeded: requestAccessIfNeeded)
    }

    // MARK: - Launch Repairs

    /// Forwarder: the launch passes live in
    /// `ConversationLaunchRepairCoordinator`; kept so existing call sites and
    /// tests keep driving them through the view model.
    func refreshConversationNames() {
        launchRepairCoordinator.refreshConversationNames()
    }

    /// Forwarder: the launch passes live in
    /// `ConversationLaunchRepairCoordinator`; kept so existing call sites and
    /// tests keep driving them through the view model.
    func repairMissingConversationPreviews() {
        launchRepairCoordinator.repairMissingConversationPreviews()
    }

    /// Forwarder: the launch passes live in
    /// `ConversationLaunchRepairCoordinator`; kept so existing call sites and
    /// tests keep driving them through the view model.
    func repairListConversationTitles() {
        launchRepairCoordinator.repairListConversationTitles()
    }

    // MARK: - Lifecycle

    /// Called when view appears - performs initial setup
    func onAppear(in context: NSManagedObjectContext) {
        startObservingConversationChanges(in: context)
        reloadConversationWindowFromStore()

        // Scheduled here rather than in deferredSetup: onDisappear cancels
        // deferredSetup, so a sheet or push in its 0.5s window used to kill
        // these before they ever ran. Both own per-launch guards and start on
        // background-priority awaits, so they cost the initial render nothing.
        launchRepairCoordinator.runLaunchRepairsIfNeeded()

        // Defer non-critical work to avoid blocking initial render
        taskManager.runDetached("deferredSetup") { [weak self] in
            // A cancelled task (onDisappear) must never run the deferred work.
            guard await Task.sleepUnlessCancelled(nanoseconds: 500_000_000) else { return } // 0.5s
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.loadContactsCache(requestAccessIfNeeded: false)
            }
        }
    }

    /// Called when view disappears
    func onDisappear(preservePreviewRepair: Bool = true) {
        // Keep observing Core Data changes across transient SwiftUI disappearances
        // caused by sheets and navigation pushes so optimistic send updates are not missed.
        selectionService.cancelTasks()
        filterService.cancelTasks()
        // Let the launch repair finish across transient navigation; it owns its
        // own per-launch guard and clears that guard if it exits incomplete.
        // The repair tasks live in the coordinator's own task manager, so the
        // view model's cancelAll never touches them — preserving the repair
        // means simply not cancelling the coordinator.
        taskManager.cancelAll()
        if !preservePreviewRepair {
            searchService.cleanup()
            launchRepairCoordinator.cancel()
        }
    }

    // MARK: - Filter & Search Reactions

    private func bindFiltering() {
        searchService.onDebouncedSearchTextChange = { [weak self] in
            self?.recomputeFilteredConversations()
        }

        filterService.onFilterStateChange = { [weak self] in
            self?.recomputeFilteredConversations()
        }
    }

    private func recomputeFilteredConversations() {
        hasLoadedAllConversationWindow = false
        loadedConversationLimit = windowProvider.initialLimit
        // A different query rebuilds the window from scratch: forget the
        // prefetch ledger so the new window's rows warm again.
        prefetchedPersonEmails.removeAll()
        reloadConversationWindowFromStore()
    }

    // MARK: - Window Paging

    /// Internal (not private) so the `+ChangeObservation` facet's
    /// invalidate-all path publishes through the same funnel as every other
    /// path.
    func publishVisibleItems() {
        let visibleItems = listStore.visibleItems
        // Single owner of selection ⊆ visible rows: every publish path (live
        // changes, trims, reloads, backfill, invalidate-all) funnels through
        // here, so no individual path has to know which rows it dropped.
        selectionService.retainSelection(within: Set(visibleItems.map(\.id)))
        guard visibleItems != filteredConversationItems else { return }
        filteredConversationItems = visibleItems
    }

    func loadMoreIfNeeded(currentItem item: ConversationListItem) {
        guard !hasLoadedAllConversationWindow else { return }
        // Page only when the appearing row sits within preloadThreshold of the
        // window's end; a row that is no longer in the window pages nothing.
        let pagingTriggerItems = filteredConversationItems.suffix(windowProvider.preloadThreshold)
        guard pagingTriggerItems.contains(where: { $0.id == item.id }) else { return }

        loadedConversationLimit += windowProvider.pageSize
        reloadConversationWindowFromStore()
    }

    private var conversationContext: NSManagedObjectContext {
        observedConversationContext ?? storage.viewContext
    }

    private func conversation(withID objectID: NSManagedObjectID) -> Conversation? {
        try? conversationContext.existingObject(with: objectID) as? Conversation
    }

    private func reloadConversationWindowFromStore() {
        // A filter/contacts-cache/search callback can fire before onAppear(in:)
        // registers a context; the first onAppear reload picks that state up
        // (observedConversationContext is weak, so no assert).
        guard observedConversationContext != nil else { return }

        let window = windowProvider.fetchWindow(
            in: conversationContext,
            limit: loadedConversationLimit,
            searchText: searchService.debouncedSearchText,
            filter: filterService.currentFilter,
            canMatchCurrentFilter: canCurrentFilterMatchConversations,
            matchesVisibility: matchesVisibleConversation(_:)
        )
        hasLoadedAllConversationWindow = window.count < loadedConversationLimit
        // Captured before replaceAll so the prefetch below targets only the
        // rows entering the window on this reload (paging's appended tail, a
        // live insert) instead of re-submitting the whole window every time.
        let previouslyVisibleIDs = Set(listStore.visibleItems.map(\.id))
        listStore.replaceAll(with: window)
        publishVisibleItems()
        let newlyVisibleItems = listStore.visibleItems.filter { !previouslyVisibleIDs.contains($0.id) }
        prefetchPersonData(from: newlyVisibleItems)
    }

    @discardableResult
    private func backfillConversationWindowIfNeeded() -> Bool {
        guard observedConversationContext != nil,
              !hasLoadedAllConversationWindow,
              listStore.visibleItems.count < loadedConversationLimit else {
            return false
        }

        reloadConversationWindowFromStore()
        return true
    }

    // MARK: - Visibility Predicates

    private var canCurrentFilterMatchConversations: Bool {
        filterService.currentFilter.canMatchAnything(
            hasContactEmails: !filterService.contactEmailsCache.isEmpty
        )
    }

    private func isSourceConversation(_ conversation: Conversation) -> Bool {
        conversation.archivedAt == nil
    }

    private func matchesVisibleConversation(_ conversation: Conversation) -> Bool {
        filterService.matches(conversation, searchText: searchService.debouncedSearchText)
    }
}
