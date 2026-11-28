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
    /// Conversations an archive or a spam report asked from the list is running for: every one
    /// of this view model's archive and spam entry points, the row's (`archiveConversation`,
    /// `reportSpamConversation`), the Mac sidebar's (`archiveConversations(withIDs:)`,
    /// `reportSpamConversations(withIDs:)`) and Select mode's. Both lists dim these rows and
    /// offer no swipe on them (`ConversationRowSwipePolicy.rowOpacity`, `offersSwipes`): a row
    /// stays until the action's save reaches this context, which for a long chat is seconds,
    /// and with nothing changed on screen the answer looked ignored. An entry point leaves out
    /// a conversation already here, so nothing runs twice for one row.
    ///
    /// Cleared when the action returns, which can be a moment before its save has reached the
    /// list, so a row can show undimmed for that moment before it goes; and a row the action
    /// left as it was (one with no messages, for the row's own actions) shows undimmed again.
    @Published private(set) var conversationIDsLeavingList: Set<NSManagedObjectID> = []

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
    /// Set when a window fetch failed and the window on screen is the one from before
    /// it: the next `.syncCompleted` reloads, and only then (`retryOwedWindowReload`),
    /// never every sync, which would refetch the whole window on the main thread after
    /// each one.
    private var windowReloadOwed = false
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
            notificationCenter: resolvedDependencies.notificationCenter,
            repairTaskPriority: resolvedDependencies.launchRepairTaskPriority
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

        // The retry of a window fetch that failed (`windowReloadOwed`): a sync's end,
        // because nothing else refetches a whole window once the list is on screen
        // (sync and pull-to-refresh reload nothing, live changes re-add only the rows
        // they touch, and only a backfill after a merged save that leaves a slot open
        // asks again before this), so the Mac's sidebar stayed wrong until a search or
        // a relaunch.
        resolvedDependencies.notificationCenter.publisher(for: .syncCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.retryOwedWindowReload()
            }
            .store(in: &cancellables)

        // The heal for rows a batch delete removed, which no change notification brings
        // (`pruneWindowRowsGoneFromStore`): asked when a cleanup run ends, because the
        // empty-conversation pass is a cleanup run's.
        resolvedDependencies.notificationCenter.publisher(for: .conversationCleanupFinished)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pruneWindowRowsGoneFromStore()
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

    /// Archives one row's conversation: a row's swipe, on the iPhone's list and the Mac's
    /// sidebar. The single-conversation action, as the row's Report Spam
    /// (`reportSpamConversation(withID:)`) is, so the swipe follows one set of rules on both.
    func archiveConversation(withID objectID: NSManagedObjectID) {
        guard let conversation = conversation(withID: objectID),
              beginLeavingList([conversation.objectID]) == [conversation.objectID] else {
            return
        }

        let convID = conversation.objectID
        runRowAction(
            "archive",
            on: conversation,
            then: { [weak self] in self?.endLeavingList([convID]) }
        ) { messageActions, conversation in
            await messageActions.archiveConversation(conversation: conversation)
        }
    }

    /// Reports one row's conversation as spam: a row's swipe, on the iPhone's list and the
    /// Mac's sidebar, once its question is answered (`View.conversationSpamConfirmation`).
    ///
    /// The single-conversation action, as the row's Archive (`archiveConversation(withID:)`)
    /// is. Not `reportSpamConversations(withIDs:)`: that is the batch entry point, which treats
    /// a conversation with no messages as a batch does (it archives it, where the
    /// single-conversation actions leave it as it is), so the row's two swipe buttons, or the
    /// two platforms' swipes, would follow different rules.
    ///
    /// The conversation is in `conversationIDsLeavingList` until the action ends, and a second
    /// report of it meanwhile is refused: a second run under the same task key would cancel
    /// the first.
    func reportSpamConversation(withID objectID: NSManagedObjectID) {
        guard let conversation = conversation(withID: objectID),
              beginLeavingList([conversation.objectID]) == [conversation.objectID] else {
            return
        }

        let convID = conversation.objectID
        runRowAction(
            "reportSpam",
            on: conversation,
            then: { [weak self] in self?.endLeavingList([convID]) }
        ) { messageActions, conversation in
            await messageActions.reportSpamConversation(conversation: conversation)
        }
    }

    /// Whether the list shows the conversation now: one of its loaded rows (see
    /// `ConversationRowSwipePolicy.withdrawsQuestion` for a row the window trims). One pass over
    /// the rows; the lists ask it while a row's spam question is up and once more when its
    /// answer runs (`View.conversationSpamConfirmation`).
    func listsConversation(withID objectID: NSManagedObjectID) -> Bool {
        filteredConversationItems.contains { $0.id == objectID }
    }

    /// Adds the named conversations to `conversationIDsLeavingList` and returns the ones that
    /// were not there yet, which are the ones the caller may act on and must end.
    private func beginLeavingList(_ conversationIDs: Set<NSManagedObjectID>) -> Set<NSManagedObjectID> {
        let starting = conversationIDs.subtracting(conversationIDsLeavingList)
        if !starting.isEmpty {
            conversationIDsLeavingList.formUnion(starting)
        }
        return starting
    }

    private func endLeavingList(_ conversationIDs: Set<NSManagedObjectID>) {
        conversationIDsLeavingList.subtract(conversationIDs)
    }

    func toggleConversationReadState(withID objectID: NSManagedObjectID) {
        guard let conversation = conversation(withID: objectID) else {
            return
        }

        runRowAction("toggleRead", on: conversation) { messageActions, conversation in
            if conversation.inboxUnreadCount > 0 {
                await messageActions.markConversationAsRead(conversation: conversation)
            } else {
                await messageActions.markConversationAsUnread(conversation: conversation)
            }
        }
    }

    /// Runs one conversation's action on this view model's task manager, under a key of its own
    /// per kind and conversation (`"<kind>-<objectID>"`): the same action asked again for the
    /// same conversation replaces the earlier task, and nothing else does.
    ///
    /// - Parameters:
    ///   - kind: The action's part of the task key. Kinds that share it share their tasks:
    ///     the Mac's read-state command runs under the row toggle's `"toggleRead"`.
    ///   - completion: Runs on the main actor once the action has returned.
    private func runRowAction(
        _ kind: String,
        on conversation: Conversation,
        then completion: (@MainActor () -> Void)? = nil,
        _ action: @escaping (MessageActions, Conversation) async -> Void
    ) {
        let convID = conversation.objectID
        taskManager.run("\(kind)-\(convID)") { [weak self] in
            guard let self = self else { return }
            await action(messageActions, conversation)
            completion?()
        }
    }

    /// What the Mac's Mark as Read / Mark as Unread command (Command-Shift-U) would do to the
    /// named conversations now: `MailboxMenuPolicy.readStateCommand` over their inbox unread
    /// counts. Nil when none of them exists any more, which disables the command.
    ///
    /// Read from the conversations themselves, as `changeReadState` does, not from the rows'
    /// snapshots: the open chat is among them even while a search hides its row.
    func readStateCommand(
        forConversationsWithIDs conversationIDs: Set<NSManagedObjectID>
    ) -> MailboxMenuPolicy.ReadStateCommand? {
        MailboxMenuPolicy.readStateCommand(
            unreadCounts: liveConversations(withIDs: conversationIDs).map { Int($0.inboxUnreadCount) }
        )
    }

    /// Runs the Mac's Mark as Read / Mark as Unread command on the named conversations: all of
    /// them one way, decided here from their counts at this moment, not from the title the
    /// menu last drew. A conversation already as the command leaves it is passed over.
    ///
    /// Each conversation's change runs as the one its row's toggle makes
    /// (`toggleConversationReadState`), under that toggle's task key.
    ///
    /// - Parameter perform: Makes one conversation's change. Nil in the app, which runs it
    ///   through `messageActions`; the tests record the calls.
    func changeReadState(
        ofConversationsWithIDs conversationIDs: Set<NSManagedObjectID>,
        perform: ((MailboxMenuPolicy.ReadStateCommand, Conversation) -> Void)? = nil
    ) {
        let conversations = liveConversations(withIDs: conversationIDs)
        guard let command = MailboxMenuPolicy.readStateCommand(
            unreadCounts: conversations.map { Int($0.inboxUnreadCount) }
        ) else {
            return
        }
        let perform = perform ?? { [weak self] command, conversation in
            self?.runReadStateChange(command, on: conversation)
        }
        for conversation in conversations
        where MailboxMenuPolicy.changesReadState(command, unreadCount: Int(conversation.inboxUnreadCount)) {
            perform(command, conversation)
        }
    }

    private func runReadStateChange(_ command: MailboxMenuPolicy.ReadStateCommand, on conversation: Conversation) {
        runRowAction("toggleRead", on: conversation) { messageActions, conversation in
            switch command {
            case .markRead:
                await messageActions.markConversationAsRead(conversation: conversation)
            case .markUnread:
                await messageActions.markConversationAsUnread(conversation: conversation)
            }
        }
    }

    /// The named conversations that still exist. One a sync deleted is left out.
    private func liveConversations(withIDs conversationIDs: Set<NSManagedObjectID>) -> [Conversation] {
        conversationIDs.compactMap { conversationID in
            guard let conversation = conversation(withID: conversationID), !conversation.isDeleted else {
                return nil
            }
            return conversation
        }
    }

    /// Select mode's Archive. The selected rows leave the list as the action runs
    /// (`conversationIDsLeavingList`); the selection service still acts on all of them, and a
    /// row already leaving is left to the action that started it.
    func archiveSelectedConversations() {
        let leaving = beginLeavingList(selectionService.selectedConversationIDs)
        selectionService.archiveSelectedConversations { [weak self] in
            self?.endLeavingList(leaving)
        }
    }

    /// Select mode's Spam. See `archiveSelectedConversations()`.
    func reportSpamSelectedConversations() {
        let leaving = beginLeavingList(selectionService.selectedConversationIDs)
        selectionService.reportSpamSelectedConversations { [weak self] in
            self?.endLeavingList(leaving)
        }
    }

    /// Archives the named rows without touching select mode: the Mac sidebar's Delete key and
    /// context menu, and the chat column's button while several rows are selected
    /// (`ConversationSelectionService.archiveConversations(withIDs:)`). A row's swipe archives
    /// through `archiveConversation(withID:)` instead. Rows already leaving the list are left
    /// out (`conversationIDsLeavingList`).
    func archiveConversations(withIDs conversationIDs: Set<NSManagedObjectID>) {
        let leaving = beginLeavingList(conversationIDs)
        guard !leaving.isEmpty else { return }
        selectionService.archiveConversations(withIDs: leaving) { [weak self] in
            self?.endLeavingList(leaving)
        }
    }

    /// Reports the named rows as spam without touching select mode. See
    /// `archiveConversations(withIDs:)`; a row's swipe reports through
    /// `reportSpamConversation(withID:)`.
    func reportSpamConversations(withIDs conversationIDs: Set<NSManagedObjectID>) {
        let leaving = beginLeavingList(conversationIDs)
        guard !leaving.isEmpty else { return }
        selectionService.reportSpamConversations(withIDs: leaving) { [weak self] in
            self?.endLeavingList(leaving)
        }
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

        // A non-empty trim opens the store's edge, which reopens paging even when a
        // short initial fetch had found the window complete.
        _ = listStore.trimVisibleItems(to: loadedConversationLimit)

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

    /// Called when view appears - performs initial setup.
    ///
    /// The window is read from the store only when it is not current: a context this view
    /// model was not observing (the first appearance), or a reload owed by a failed fetch
    /// or an invalidate-all. The iOS list appears again on every pop from a chat, and until
    /// 2026-11-28 each appearance re-read and re-snapshotted the whole window, however
    /// deep the user had paged, on the main thread (architecture review 2026-11,
    /// conversation-list-ui#3). The window stays current while hidden: the view model keeps
    /// observing across `onDisappear`, so every change reaches it. That reload was also the
    /// only heal for rows a batch delete removed, which `pruneWindowRowsGoneFromStore`
    /// now is.
    func onAppear(in context: NSManagedObjectContext) {
        let observesAnotherContext = observedConversationContext !== context
        startObservingConversationChanges(in: context)
        if observesAnotherContext || windowReloadOwed {
            reloadConversationWindowFromStore()
        }

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
        loadedConversationLimit = windowProvider.initialLimit
        // A different query rebuilds the window from scratch: forget the
        // prefetch ledger so the new window's rows warm again.
        prefetchedPersonEmails.removeAll()
        reloadConversationWindowFromStore(afterQueryChange: true)
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
        guard !listStore.isComplete else { return }
        // Page only when the appearing row sits within preloadThreshold of the
        // window's end; a row that is no longer in the window pages nothing.
        let pagingTriggerItems = filteredConversationItems.suffix(windowProvider.preloadThreshold)
        guard pagingTriggerItems.contains(where: { $0.id == item.id }) else { return }

        let previousLimit = loadedConversationLimit
        loadedConversationLimit += windowProvider.pageSize
        if !fillWindowFromStore() {
            // Left raised, `backfillConversationWindowIfNeeded` would run the failing
            // fetch again after every relevant merged save.
            loadedConversationLimit = previousLimit
        }
    }

    /// Fills the window up to the limit with the rows past its edge, and returns whether it
    /// was read: one keyset page of the missing rows (`ConversationWindowProvider.fetchPage`)
    /// where the query's store predicate is exact (`pagesByKeyset`) and the window ends at a
    /// known row (`ConversationListStore.pageStartKey`), else the full reload. Until
    /// 2026-11-28 a page, and the backfill after a removal, reloaded and re-snapshotted the
    /// whole window from its first row on the main thread (architecture review 2026-11,
    /// conversation-list-ui#3). A search and the contact filters keep the full reload: their
    /// rows are re-checked in memory, so the store's next rows are not the window's.
    ///
    /// A failed page keeps the window as it is, open, and owes the reload a failed full
    /// fetch owes (`windowReloadOwed`).
    @discardableResult
    private func fillWindowFromStore() -> Bool {
        guard observedConversationContext != nil else { return false }
        let missingCount = loadedConversationLimit - listStore.visibleItems.count
        guard missingCount > 0 else { return true }
        guard windowProvider.pagesByKeyset(
            searchText: searchService.debouncedSearchText,
            filter: filterService.currentFilter
        ),
        let pageStart = listStore.pageStartKey else {
            return reloadConversationWindowFromStore()
        }

        let page: ConversationWindowProvider.Window
        do {
            page = try windowProvider.fetchPage(
                in: conversationContext,
                after: pageStart,
                limit: missingCount,
                filter: filterService.currentFilter,
                matchesVisibility: matchesVisibleConversation(_:)
            )
        } catch {
            Log.error(
                "Failed to fetch the next rows of the conversation window; keeping the one on screen until the next sync",
                category: .conversation,
                error: error
            )
            windowReloadOwed = true
            return false
        }
        let appended = listStore.appendPage(page.rows, isComplete: page.isComplete)
        publishVisibleItems()
        prefetchPersonData(from: appended)
        return true
    }

    private var conversationContext: NSManagedObjectContext {
        observedConversationContext ?? storage.viewContext
    }

    private func conversation(withID objectID: NSManagedObjectID) -> Conversation? {
        try? conversationContext.existingObject(with: objectID) as? Conversation
    }

    /// Returns whether the window was read. A read that fails keeps the window on
    /// screen, leaves paging open and owes a reload (`windowReloadOwed`): until
    /// 2026-11-27 `fetchWindow` answered `[]` for a fetch error, the latch closed on it
    /// (0 < limit) and a failure on a paging step replaced a populated list with
    /// nothing that looked final (architecture review 2026-11, conversation-list-ui#6).
    /// `afterQueryChange` says the window on screen answers another query (search text,
    /// filter, contact set): then a failed read clears it, as a query that matched
    /// nothing would, instead of showing rows the new query excludes.
    @discardableResult
    private func reloadConversationWindowFromStore(afterQueryChange: Bool = false) -> Bool {
        // A filter/contacts-cache/search callback can fire before onAppear(in:)
        // registers a context; the first onAppear reload picks that state up
        // (observedConversationContext is weak, so no assert).
        guard observedConversationContext != nil else { return false }

        let window: ConversationWindowProvider.Window
        do {
            window = try windowProvider.fetchWindowReportingCompleteness(
                in: conversationContext,
                limit: loadedConversationLimit,
                searchText: searchService.debouncedSearchText,
                filter: filterService.currentFilter,
                canMatchCurrentFilter: canCurrentFilterMatchConversations,
                matchesVisibility: matchesVisibleConversation(_:)
            )
        } catch {
            Log.error(
                "Failed to fetch the conversation window; keeping the one on screen until the next sync",
                category: .conversation,
                error: error
            )
            windowReloadOwed = true
            if afterQueryChange {
                listStore.replaceAll(with: [], isComplete: false)
                publishVisibleItems()
            } else {
                listStore.markOpen()
            }
            return false
        }
        windowReloadOwed = false
        // Captured before replaceAll so the prefetch below targets only the
        // rows entering the window on this reload (paging's appended tail, a
        // live insert) instead of re-submitting the whole window every time.
        let previouslyVisibleIDs = Set(listStore.visibleItems.map(\.id))
        listStore.replaceAll(with: window.rows, isComplete: window.isComplete)
        publishVisibleItems()
        let newlyVisibleItems = listStore.visibleItems.filter { !previouslyVisibleIDs.contains($0.id) }
        prefetchPersonData(from: newlyVisibleItems)
        return true
    }

    /// The reload a failed fetch left owed, at a sync's end and only then.
    private func retryOwedWindowReload() {
        guard windowReloadOwed else { return }
        reloadConversationWindowFromStore()
    }

    /// The observed context was reset wholesale (`NSInvalidatedAllObjectsKey`), so the
    /// window is gone (`ConversationListStore.removeAll` opened its edge, so paging
    /// reopens) and a reload is owed. Nothing is fetched here: the reset runs between
    /// the store's destroy and its reload, where a fetch traps; `onAppear` or the next
    /// sync's end refetches. Internal (not private) for the `+ChangeObservation` facet.
    func noteWindowInvalidated() {
        windowReloadOwed = true
    }

    /// Returns whether the backfill read and published the window (a keyset page of the
    /// missing rows where it can, `fillWindowFromStore`). A backfill whose fetch failed
    /// answers false, so the caller publishes the live changes it already
    /// applied (a deletion or an archive that opened the slot) and the row leaves the
    /// screen; the reload stays owed. Answering true there, as the first version of the
    /// failure branch did, left the removed row visible and selectable until a later
    /// reload (Codex's review of PR 503).
    @discardableResult
    private func backfillConversationWindowIfNeeded() -> Bool {
        guard observedConversationContext != nil,
              !listStore.isComplete,
              listStore.visibleItems.count < loadedConversationLimit else {
            return false
        }

        return fillWindowFromStore()
    }

    /// Removes the window rows the store no longer has, which no change notification
    /// reports. The empty-conversation pass deletes in a batch
    /// (`DataCleanupService.removeEmptyConversations`), and a batch delete merged into this
    /// context reaches only the rows it has registered, while the list holds snapshots of
    /// rows that may have been let go: such a row stayed on screen, and a tap opened a chat
    /// that was gone. Until 2026-11-28 the full reload of every iOS appearance healed it;
    /// the Mac, which appears once, never did. Asked when a cleanup run ends: one fetch of
    /// the window's stored rows by key, returning their IDs alone.
    ///
    /// An unsaved row (an optimistic send's, which may hold a permanent ID) is not in the
    /// store and is not asked about. Nothing is asked while the context's coordinator has
    /// no store, whose fetch answers `[]` with no error and would empty the window.
    private func pruneWindowRowsGoneFromStore() {
        guard let context = observedConversationContext else { return }
        context.performAndWait {
            MainActor.assumeIsolated {
                guard CoreDataStack.hasAttachedStore(context) else { return }
                let storedIDs = listStore.visibleItems.map(\.id).filter { objectID in
                    guard !objectID.isTemporaryID else { return false }
                    return context.registeredObject(for: objectID)?.isInserted != true
                }
                guard !storedIDs.isEmpty else { return }

                let request = NSFetchRequest<NSManagedObjectID>(entityName: "Conversation")
                request.resultType = .managedObjectIDResultType
                request.predicate = NSPredicate(format: "self IN %@", storedIDs)
                request.includesPendingChanges = false
                let presentIDs: Set<NSManagedObjectID>
                do {
                    presentIDs = Set(try context.fetch(request))
                } catch {
                    // A failed read is not an empty answer: nothing is removed.
                    Log.error("Failed to check the conversation window against the store", category: .conversation, error: error)
                    return
                }
                let goneIDs = Set(storedIDs).subtracting(presentIDs)
                guard !goneIDs.isEmpty else { return }
                applyConversationChanges(deletedIDs: goneIDs)
            }
        }
    }

    // MARK: - Visibility Predicates

    private var canCurrentFilterMatchConversations: Bool {
        filterService.currentFilter.canMatchAnything(
            hasContactEmails: !filterService.contactEmailsCache.isEmpty
        )
    }

    /// Internal (not private) so the `+ChangeObservation` facet's sibling-save path
    /// can ask `ConversationListStore.admittance` before it prefetches participants.
    func isSourceConversation(_ conversation: Conversation) -> Bool {
        conversation.archivedAt == nil
    }

    private func matchesVisibleConversation(_ conversation: Conversation) -> Bool {
        filterService.matches(conversation, searchText: searchService.debouncedSearchText)
    }
}
