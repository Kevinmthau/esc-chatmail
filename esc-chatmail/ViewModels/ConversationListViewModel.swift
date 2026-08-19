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
    static let conversationNameRefreshMigrationKey = "hasRefreshedConversationNamesV6"
    /// Completion marker only — the preview repair re-runs every launch and no
    /// longer skips when this flag is already set.
    static let conversationPreviewRepairMigrationKey = "hasRepairedMissingConversationPreviewsV2"
    private static let repairMissingConversationPreviewsTaskKey = "repairMissingConversationPreviews"

    // MARK: - Composed Services

    let searchService: ConversationSearchService
    let selectionService: ConversationSelectionService
    let filterService: ConversationFilterService

    // MARK: - Published State (Presentation)

    @Published private(set) var filteredConversationItems: [ConversationListItem] = []

    // MARK: - Dependencies

    let messageActions: MessageActions
    let syncEngine: SyncEngine
    let foregroundSyncCoordinator: ForegroundSyncCoordinator
    let conversationManager: ConversationManager

    private let storage: StorageDependencies
    private var cancellables = Set<AnyCancellable>()
    private var conversationChangesCancellable: AnyCancellable?
    private var conversationSavesCancellable: AnyCancellable?
    private let taskManager = ViewModelTaskManager()
    private var listStore = ConversationListStore()
    private let windowProvider: ConversationWindowProvider
    private var loadedConversationLimit: Int
    private var hasLoadedAllConversationWindow = false
    private var isConversationPreviewRepairRunning = false
    private var hasCompletedConversationPreviewRepair = false
    private var hasObservedSyncCompletionThisLaunch = false
    private weak var observedConversationContext: NSManagedObjectContext?

    // MARK: - Initialization

    /// Primary initializer using the narrowed conversation-list bundle.
    init(
        dependencies: ConversationListDependencies? = nil,
        searchService: ConversationSearchService? = nil,
        selectionService: ConversationSelectionService? = nil,
        filterService: ConversationFilterService? = nil,
        windowProvider: ConversationWindowProvider = ConversationWindowProvider()
    ) {
        let resolvedDependencies = dependencies ?? Dependencies.shared.makeConversationListDependencies()
        self.storage = resolvedDependencies.storage
        self.syncEngine = resolvedDependencies.syncEngine
        self.foregroundSyncCoordinator = resolvedDependencies.foregroundSyncCoordinator
        self.messageActions = resolvedDependencies.messaging.makeMessageActions()
        self.conversationManager = resolvedDependencies.conversationManager
        self.windowProvider = windowProvider
        self.loadedConversationLimit = windowProvider.initialLimit

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
        bindSyncCompletionRepairRearm()
    }

    /// Re-arms the launch preview repair when a sync run finishes before the
    /// repair has completed: the launch pass can legitimately drain an empty
    /// store before the first sync registers (fresh install), so the first
    /// completed sync gets a fresh sweep. Once the repair completes it stays
    /// done for the launch — incremental syncs post this notification on every
    /// run, and re-sweeping each time would repeat the archive/repair fetches
    /// forever; per-page rollups already keep synced pages presentable.
    private func bindSyncCompletionRepairRearm() {
        NotificationCenter.default.publisher(for: .syncCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.hasObservedSyncCompletionThisLaunch = true
                self.repairMissingConversationPreviews()
            }
            .store(in: &cancellables)
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
        filteredConversationItems.compactMap { conversation(withID: $0.id) }
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
        guard let conversation = conversation(withID: objectID) else {
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

    func isConversationWithContact(_ conversation: Conversation) -> Bool {
        filterService.isConversationWithContact(conversation)
    }

    // MARK: - Data Loading

    func prefetchPersonData(from items: [ConversationListItem]) {
        let personCache = storage.personCache
        let profilePhotoResolver = storage.profilePhotoResolver

        let config = VirtualScrollConfiguration.default
        let prefetchCount = config.visibleItemCount + config.bufferSize  // 30
        let allEmails = items.prefix(prefetchCount).flatMap(\.snapshot.participantEmails)
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
        // V6: refresh stored conversation display names only. Rollup metadata stays sync-owned.
        let hasRefreshedKey = Self.conversationNameRefreshMigrationKey
        let migrationFlags = storage.migrationFlags
        guard !migrationFlags.bool(forKey: hasRefreshedKey) else { return }
        // An empty store means the initial sync has not landed yet (fresh
        // install), not that every name is refreshed — leave the flag unset so
        // the migration still runs once conversations exist.
        guard storeHasConversations() else { return }

        taskManager.run("refreshNames") { [weak self] in
            guard let self = self else { return }
            let context = storage.makeBackgroundContext()
            await conversationManager.updateAllConversationDisplayNames(in: context)
            guard storage.saveIfNeeded(context) else { return }
            migrationFlags.set(true, forKey: hasRefreshedKey)
            Log.info("Refreshed conversation display names (V6)", category: .conversation)
        }
    }

    func repairMissingConversationPreviews() {
        // Runs once per launch, not once per install: interrupted syncs can
        // re-create both broken states (missing previews and stranded
        // message-less shells) at any time, so a one-shot migration flag
        // leaves later breakage visible forever.
        guard !isConversationPreviewRepairRunning,
              !hasCompletedConversationPreviewRepair else { return }
        isConversationPreviewRepairRunning = true

        let hasRepairedKey = Self.conversationPreviewRepairMigrationKey
        let migrationFlags = storage.migrationFlags

        taskManager.run(Self.repairMissingConversationPreviewsTaskKey, priority: .background) { [weak self] in
            guard let self = self else { return }
            var didCompleteRepair = false
            defer {
                isConversationPreviewRepairRunning = false
                if didCompleteRepair {
                    hasCompletedConversationPreviewRepair = true
                }
            }

            // A running sync may have saved a conversation shell whose first
            // message has not persisted yet; sweeping shells mid-sync could
            // archive a row that is about to receive its message.
            await syncEngine.waitForCurrentSyncToComplete()
            guard !Task.isCancelled else { return }

            // Sampled before the sweep: an empty drain on an empty store must
            // not count as completion (see the didDrain gate below).
            let storeHadConversations = storeHasConversations()

            let context = storage.makeBackgroundContext()
            // Store-trump on purpose (opposite of the app-wide object-trump
            // default): if live sync saves fresher rollups while this pass
            // holds stale in-memory values, the store version must win; the
            // sync-completion re-arm re-sweeps anything still broken.
            context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy

            let archivedCount = await conversationManager.archiveMessagelessConversations(in: context)
            if archivedCount > 0 {
                guard storage.saveIfNeeded(context) else {
                    Log.error(
                        "Failed to save \(archivedCount) archived message-less conversations; skipping preview repair",
                        category: .conversation
                    )
                    return
                }
                Log.info("Archived \(archivedCount) stranded message-less conversations", category: .conversation)
            }

            var totalRepairedCount = 0
            while !Task.isCancelled {
                let result = await conversationManager.repairMissingConversationPreviews(in: context)
                if result.repairedCount > 0 {
                    guard storage.saveIfNeeded(context) else { return }
                    totalRepairedCount += result.repairedCount
                }

                if result.didDrain {
                    if totalRepairedCount > 0 {
                        Log.info("Repaired missing conversation previews: \(totalRepairedCount)", category: .conversation)
                    }
                    // Draining an empty store says nothing about repair health:
                    // on a fresh install this pass can beat the first sync run's
                    // registration. Stay armed so the sync-completion re-arm
                    // sweeps the store once data actually exists.
                    guard storeHadConversations || hasObservedSyncCompletionThisLaunch else { return }
                    migrationFlags.set(true, forKey: hasRepairedKey)
                    didCompleteRepair = true
                    return
                }

                guard result.repairedCount > 0 else {
                    if totalRepairedCount > 0 {
                        Log.info("Repaired missing conversation previews: \(totalRepairedCount)", category: .conversation)
                    }
                    return
                }

                await Task.yield()
            }
        }
    }

    /// Called when view appears - performs initial setup
    func onAppear(in context: NSManagedObjectContext) {
        startObservingConversationChanges(in: context)
        reloadConversationWindowFromStore()

        // Scheduled here rather than in deferredSetup: onDisappear cancels
        // deferredSetup, so a sheet or push in its 0.5s window used to kill
        // these before they ever ran. Both own per-launch guards and start on
        // background-priority awaits, so they cost the initial render nothing.
        refreshConversationNames()
        repairMissingConversationPreviews()

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
        if preservePreviewRepair {
            // Let the launch repair finish across transient navigation; it owns its
            // own per-launch guard and clears that guard if it exits incomplete.
            taskManager.cancelAll(except: [Self.repairMissingConversationPreviewsTaskKey])
        } else {
            searchService.cleanup()
            taskManager.cancelAll()
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
        guard let index = filteredConversationItems.firstIndex(where: { $0.id == item.id }) else { return }
        guard filteredConversationItems.distance(from: index, to: filteredConversationItems.endIndex) <= windowProvider.preloadThreshold else {
            return
        }

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
        listStore.replaceAll(with: window)
        publishVisibleItems()
        prefetchPersonData(from: filteredConversationItems)
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

    /// Whether any conversations exist in the persistent store. Gates the
    /// launch-time name refresh and preview repair so neither treats a
    /// fresh install's empty store as successful completion.
    private func storeHasConversations() -> Bool {
        let request = Conversation.fetchRequest()
        request.includesPendingChanges = false

        do {
            return try storage.viewContext.count(for: request) > 0
        } catch {
            Log.error("Failed to count conversations for launch repair passes", category: .conversation, error: error)
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
