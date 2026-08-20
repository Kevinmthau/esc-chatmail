import Foundation
import CoreData
import Contacts
import Combine

/// Filter options for the conversation list
enum ConversationFilter: String, CaseIterable {
    case all = "All"
    case unread = "Unread"
    case contacts = "Contacts"
    case other = "Other"

    var icon: String {
        switch self {
        case .all: return "line.3.horizontal.decrease"
        case .unread: return "envelope.badge"
        case .contacts: return "person.crop.circle"
        case .other: return "person.crop.circle.badge.questionmark"
        }
    }
}

/// ViewModel for ConversationListView - manages list state and operations
/// Composes specialized services for search, selection, and filtering
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
    private var cancellables = Set<AnyCancellable>()
    private var conversationChangesCancellable: AnyCancellable?
    private var conversationSavesCancellable: AnyCancellable?
    private let taskManager = ViewModelTaskManager()
    private var listStore = ConversationListStore()
    private let windowProvider: ConversationWindowProvider
    private var loadedConversationLimit: Int
    private var hasLoadedAllConversationWindow = false
    /// Emails already handed to the person/avatar prefetchers for the current
    /// window generation. Reset when the query changes or the store is
    /// invalidated wholesale, so a genuinely fresh window prefetches again.
    private var prefetchedPersonEmails: Set<String> = []
    private weak var observedConversationContext: NSManagedObjectContext?

    // MARK: - Initialization

    /// Primary initializer using the narrowed conversation-list bundle.
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

    // MARK: - Filtering (Delegate to Service)

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

    // MARK: - Data Loading

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

    private func publishVisibleItems() {
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

    private var canCurrentFilterMatchConversations: Bool {
        switch filterService.currentFilter {
        case .all, .unread, .other:
            return true
        case .contacts:
            return !filterService.contactEmailsCache.isEmpty
        }
    }

    private func isSourceConversation(_ conversation: Conversation) -> Bool {
        conversation.archivedAt == nil
    }

    private func matchesVisibleConversation(_ conversation: Conversation) -> Bool {
        filterService.matches(conversation, searchText: searchService.debouncedSearchText)
    }

    private func startObservingConversationChanges(in context: NSManagedObjectContext) {
        guard observedConversationContext !== context
                || conversationChangesCancellable == nil
                || conversationSavesCancellable == nil else {
            return
        }

        conversationChangesCancellable?.cancel()
        conversationSavesCancellable?.cancel()
        observedConversationContext = context
        conversationChangesCancellable = NotificationCenter.default.publisher(
            for: .NSManagedObjectContextObjectsDidChange,
            object: context
        )
        .sink { [weak self] notification in
            self?.handleConversationContextChange(notification)
        }

        // Registration-independent delivery for sibling-context saves. The
        // automerge into the observed context only *refreshes* objects still
        // registered there, and this list holds objectIDs + value snapshots,
        // never the managed objects — so a background rollup save for a
        // conversation whose object has deallocated (or that sits outside the
        // loaded window) can produce no Conversation in objectsDidChange,
        // leaving the row stale until relaunch. didSaveObjectIDs is posted by
        // every saving context and carries only thread-safe NSManagedObjectIDs.
        let coordinator = context.persistentStoreCoordinator
        conversationSavesCancellable = NotificationCenter.default.publisher(
            for: NSManagedObjectContext.didSaveObjectIDsNotification
        )
        .filter { [weak context] notification in
            // Runs on the saving context's thread; objectID entity checks only,
            // nothing faults. The coordinator check scopes delivery to our
            // store, and the identity check skips the observed context's own
            // saves, which already flowed through objectsDidChange.
            guard let context,
                  let sourceContext = notification.object as? NSManagedObjectContext,
                  sourceContext !== context,
                  sourceContext.persistentStoreCoordinator === coordinator else {
                return false
            }
            return Self.isRelevantConversationSave(notification.userInfo)
        }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            self?.handleSiblingContextSave(notification)
        }
    }

    private func handleConversationContextChange(_ notification: Notification) {
        guard notification.userInfo?[NSInvalidatedAllObjectsKey] == nil else {
            listStore.removeAll()
            // The wholesale invalidation empties the window; whatever fills it
            // next is a fresh window generation and must prefetch again.
            prefetchedPersonEmails.removeAll()
            publishVisibleItems()
            return
        }

        // objectsDidChange fires for every merged sync save; most merges carry
        // only Message/Attachment/Label churn the list doesn't render, yet the
        // passes below re-scan every changed set. Bail out early unless the
        // change can actually affect the list.
        guard Self.isRelevantConversationListChange(notification.userInfo) else {
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

    /// Single-pass early-return relevance scan for objectsDidChange payloads:
    /// relevant when any Conversation appears in {inserted, updated,
    /// refreshed, deleted, invalidated} or any Person in {updated, refreshed}
    /// (display-name enrichment). The refreshed set is mandatory — merged
    /// background rollup updates surface as Conversation *refreshes*, so
    /// omitting it would break live list updates. Type checks only; nothing
    /// here faults an object.
    nonisolated static func isRelevantConversationListChange(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let userInfo else { return false }

        let keys = [
            NSInsertedObjectsKey,
            NSUpdatedObjectsKey,
            NSRefreshedObjectsKey,
            NSDeletedObjectsKey,
            NSInvalidatedObjectsKey
        ]
        let personKeys: Set<String> = [NSUpdatedObjectsKey, NSRefreshedObjectsKey]

        for key in keys {
            guard let objects = userInfo[key] as? Set<NSManagedObject> else { continue }
            let includesPersons = personKeys.contains(key)
            for object in objects {
                if object is Conversation {
                    return true
                }
                if includesPersons, object is Person {
                    return true
                }
            }
        }
        return false
    }

    /// Save-notification analog of `isRelevantConversationListChange`:
    /// relevant when any inserted/updated/deleted objectID is a Conversation.
    /// Most saves carry only Message/Attachment/Label churn; this gate runs on
    /// the saving context's thread so those never cost a main-queue hop.
    /// ObjectID entity checks only; nothing here faults an object.
    nonisolated static func isRelevantConversationSave(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let userInfo else { return false }

        for key in [NSInsertedObjectIDsKey, NSUpdatedObjectIDsKey, NSDeletedObjectIDsKey] {
            guard let objectIDs = userInfo[key] as? Set<NSManagedObjectID> else { continue }
            if objectIDs.contains(where: { $0.entity.name == "Conversation" }) {
                return true
            }
        }
        return false
    }

    /// Applies a sibling context's saved Conversation changes to the list.
    ///
    /// Runs on the main queue. On the production viewContext (a main-queue
    /// context) the `performAndWait` executes inline — identical to a direct
    /// call. On a private-queue observed context (test stacks) it serializes
    /// this pipeline with the automerge's merge blocks and the
    /// objectsDidChange sink that fires inside them, so neither the context
    /// nor the list store is ever touched from two threads at once.
    /// Whichever pipeline lands first, `existingObject(with:)` reads the
    /// saved row (faulted fresh from the store or refreshed by the merge),
    /// and a duplicate pass rebuilds identical snapshots that
    /// `publishVisibleItems`'s equality guard suppresses.
    private func handleSiblingContextSave(_ notification: Notification) {
        guard let context = observedConversationContext else { return }

        let insertedIDs = conversationSaveObjectIDs(forKey: NSInsertedObjectIDsKey, in: notification)
        let updatedIDs = conversationSaveObjectIDs(forKey: NSUpdatedObjectIDsKey, in: notification)
        let deletedIDs = conversationSaveObjectIDs(forKey: NSDeletedObjectIDsKey, in: notification)

        context.performAndWait {
            // existingObject throws for rows a later save already deleted;
            // dropping them is correct — the delete's own notification
            // removes the row.
            let updatedConversations = insertedIDs.union(updatedIDs).compactMap { objectID in
                try? context.existingObject(with: objectID) as? Conversation
            }

            // performAndWait executes on the calling thread — main, per the
            // .receive(on:) above — while holding the context's queue, so
            // this is main-actor work serialized against merge blocks and
            // the objectsDidChange sink that fires inside them.
            MainActor.assumeIsolated {
                applyConversationChanges(
                    updatedConversations: updatedConversations,
                    deletedIDs: deletedIDs
                )
            }
        }
    }

    private func conversationSaveObjectIDs(forKey key: String, in notification: Notification) -> Set<NSManagedObjectID> {
        let objectIDs = notification.userInfo?[key] as? Set<NSManagedObjectID> ?? []
        return Set(objectIDs.filter { $0.entity.name == "Conversation" })
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
