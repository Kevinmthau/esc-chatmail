import SwiftUI
import CoreData
import Combine

// `NSManagedObjectID` is the cross-context token Core Data intends us to pass
// between queues, so this payload is safe to move across task boundaries.
struct VirtualScrollMessagePage: @unchecked Sendable {
    let messageIDs: [NSManagedObjectID]
    let totalCount: Int
}

// MARK: - Virtual Scroll State
@MainActor
final class VirtualScrollState: ObservableObject {
    enum InitialWindowPosition {
        case beginning
        case end
    }

    typealias MessagePageLoader = (
        _ conversationId: String,
        _ range: Range<Int>,
        _ context: NSManagedObjectContext
    ) async -> VirtualScrollMessagePage

    @Published var visibleMessages: [ChatMessageRowModel] = []
    @Published var totalMessageCount = 0
    @Published var scrollPosition: Int = 0
    @Published var isLoadingMore = false
    @Published private(set) var isInitialLoadComplete = false
    @Published var placeholderIndices: Set<Int> = []
    @Published private(set) var insertedVisibleMessageIDs: [NSManagedObjectID] = []

    private let configuration: VirtualScrollConfiguration
    private let initialWindowPosition: InitialWindowPosition
    private var messageWindow: MessageWindow?
    private let conversationId: String
    private let viewContext: NSManagedObjectContext
    private let makeBackgroundContext: () -> NSManagedObjectContext
    private let pageLoader: MessagePageLoader

    // Cache only lightweight row snapshots for the current window. Background
    // contexts fetch IDs, and the UI never stores `Message` instances here.
    private var resolvedRowsByID: [NSManagedObjectID: ChatMessageRowModel] = [:]
    private var resolvedRowsByAbsoluteIndex: [Int: ChatMessageRowModel] = [:]
    private var viewContextChangesCancellable: AnyCancellable?
    private var cachedConversationObjectID: NSManagedObjectID?

    // Task tracking to prevent orphaned tasks during rapid scrolling
    private let taskManager = ViewModelTaskManager()
    private let localMutationRefreshTaskKey = "refreshLatestWindowForLocalMutation"

    init(
        conversationId: String,
        configuration: VirtualScrollConfiguration = .default,
        initialWindowPosition: InitialWindowPosition = .beginning
    ) {
        self.conversationId = conversationId
        self.configuration = configuration
        self.initialWindowPosition = initialWindowPosition
        self.viewContext = CoreDataStack.shared.viewContext
        self.makeBackgroundContext = { CoreDataStack.shared.newBackgroundContext() }
        self.pageLoader = VirtualScrollState.loadMessagePage
        startObservingViewContextChanges()
        loadInitialMessages()
    }

    init(
        conversationId: String,
        configuration: VirtualScrollConfiguration = .default,
        initialWindowPosition: InitialWindowPosition = .beginning,
        viewContext: NSManagedObjectContext,
        makeBackgroundContext: @escaping () -> NSManagedObjectContext,
        pageLoader: @escaping MessagePageLoader = VirtualScrollState.loadMessagePage,
        autoLoad: Bool = true
    ) {
        self.conversationId = conversationId
        self.configuration = configuration
        self.initialWindowPosition = initialWindowPosition
        self.viewContext = viewContext
        self.makeBackgroundContext = makeBackgroundContext
        self.pageLoader = pageLoader
        startObservingViewContextChanges()

        if autoLoad {
            loadInitialMessages()
        }
    }

    /// Notifies the scroll state that a message at the given index is now visible.
    /// Called from onAppear for each message in the LazyVStack.
    func markIndexVisible(_ index: Int) {
        // Skip small position changes to avoid excessive updates during scroll
        // This prevents 10+ calls per scroll when each visible message fires onAppear
        guard abs(index - scrollPosition) > 2 else { return }

        scrollPosition = index
        updateVisibleMessages()
        preloadIfNeeded()
    }

    var visibleRangeStartIndex: Int {
        messageWindow?.startIndex ?? 0
    }

    var isShowingLatestWindow: Bool {
        guard let messageWindow else { return false }
        return messageWindow.endIndex >= totalMessageCount
    }

    private var hasPendingInsertedMessagesInConversation: Bool {
        guard let conversationUUID = UUID(uuidString: conversationId) else { return false }

        return viewContext.insertedObjects.contains { object in
            guard let message = object as? Message else { return false }
            return message.conversation?.id == conversationUUID
        }
    }

    func absoluteIndex(forVisibleIndex index: Int) -> Int? {
        guard index >= 0, index < visibleMessages.count else {
            return nil
        }

        return visibleRangeStartIndex + index
    }

    private func loadInitialMessages() {
        isInitialLoadComplete = false
        isLoadingMore = true
        Log.diagnostic(
            .chatView,
            level: .info,
            "VirtualScroll initial load start conv=\(conversationId) position=\(initialWindowPosition.diagnosticName)",
            category: .ui
        )

        taskManager.run("loadInitial") { [weak self] in
            guard let self = self else { return }

            let preferPendingConversationMessages =
                self.initialWindowPosition == .end && self.hasPendingInsertedMessagesInConversation
            var initialRange = await self.initialMessageRange(
                preferPendingConversationMessages: preferPendingConversationMessages
            )
            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll initial load request conv=\(self.conversationId) range=\(initialRange.lowerBound)..<\(initialRange.upperBound)",
                category: .ui
            )
            var page = await self.loadPage(
                initialRange,
                preferPendingConversationMessages: preferPendingConversationMessages
            )

            guard !Task.isCancelled else { return }

            if self.shouldReloadInitialEndWindowForPendingLocalMessages(
                preferredPendingMessages: preferPendingConversationMessages
            ) {
                initialRange = await self.initialMessageRange(
                    preferPendingConversationMessages: true
                )
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "VirtualScroll initial load switching to pending local messages conv=\(self.conversationId) range=\(initialRange.lowerBound)..<\(initialRange.upperBound)",
                    category: .ui
                )
                page = await self.loadPage(
                    initialRange,
                    preferPendingConversationMessages: true
                )
            }

            guard !Task.isCancelled else { return }

            let messages = await self.resolveRowsOnViewContext(for: page.messageIDs)

            guard !Task.isCancelled else { return }

            let endIndex = initialRange.lowerBound + page.messageIDs.count
            let window = MessageWindow(
                startIndex: initialRange.lowerBound,
                endIndex: endIndex,
                messageIDs: page.messageIDs,
                isLoading: false
            )

            self.totalMessageCount = page.totalCount
            self.scrollPosition = initialRange.lowerBound
            self.setMessageWindow(window)
            self.visibleMessages = messages
            self.isLoadingMore = false
            self.isInitialLoadComplete = true
            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll initial load complete conv=\(self.conversationId) requested=\(initialRange.lowerBound)..<\(initialRange.upperBound) loaded=\(page.messageIDs.count) total=\(page.totalCount) window=\(window.startIndex)..<\(window.endIndex)",
                category: .ui
            )
        }
    }

    func loadLatestWindowIfNeeded(knownTotalCount: Int? = nil) async {
        let knownCountIsAhead = knownTotalCount.map { $0 > totalMessageCount } ?? false
        guard knownCountIsAhead ||
            !isShowingLatestWindow ||
            visibleMessages.isEmpty ||
            hasPendingInsertedMessagesInConversation else {
            return
        }

        await loadLatestWindow()
    }

    func refreshLatestWindowForLocalMutation(knownTotalCount: Int? = nil) async {
        await loadLatestWindowIfNeeded(knownTotalCount: knownTotalCount)
    }

    func loadLatestWindow() async {
        let preferPendingConversationMessages = hasPendingInsertedMessagesInConversation
        Log.diagnostic(
            .chatView,
            level: .info,
            "VirtualScroll latest window load start conv=\(conversationId) preferPending=\(preferPendingConversationMessages)",
            category: .ui
        )
        let totalCount = await loadTotalMessageCount(
            preferPendingConversationMessages: preferPendingConversationMessages
        )
        let startIndex = max(0, totalCount - configuration.visibleItemCount)
        await loadWindow(
            startIndex: startIndex,
            endIndex: totalCount,
            preferPendingConversationMessages: preferPendingConversationMessages
        )
        scrollPosition = max(startIndex, totalCount - 1)
        Log.diagnostic(
            .chatView,
            level: .info,
            "VirtualScroll latest window load complete conv=\(conversationId) total=\(totalCount) window=\(startIndex)..<\(totalCount)",
            category: .ui
        )
    }

    private func updateVisibleMessages() {
        guard let window = messageWindow else { return }

        let startIndex = max(0, scrollPosition - configuration.bufferSize)
        let endIndex = min(totalMessageCount, scrollPosition + configuration.visibleItemCount + configuration.bufferSize)

        if window.contains(index: startIndex) && window.contains(index: endIndex - 1) {
            // Current window already covers the requested range.
            // Keep rendering the whole window so the user can continue scrolling
            // through the buffered messages without the view pruning rows away.
            visibleMessages = resolveCachedRows(for: window.messageIDs)
        } else {
            // Need to load a new window.
            let preferPendingConversationMessages = hasPendingInsertedMessagesInConversation
            taskManager.run("loadWindow") { [weak self] in
                guard let self = self else { return }
                await self.loadWindow(
                    startIndex: startIndex,
                    endIndex: endIndex,
                    preferPendingConversationMessages: preferPendingConversationMessages
                )
            }
        }
    }

    private func loadWindow(
        startIndex: Int,
        endIndex: Int,
        preferPendingConversationMessages: Bool = false
    ) async {
        guard startIndex >= 0, endIndex >= startIndex else {
            return
        }

        isLoadingMore = true

        // Show placeholders while loading
        placeholderIndices = Set(startIndex..<endIndex)

        let page = await loadPage(
            startIndex..<endIndex,
            preferPendingConversationMessages: preferPendingConversationMessages
        )

        guard !Task.isCancelled else { return }

        let messages = await resolveRowsOnViewContext(for: page.messageIDs)

        guard !Task.isCancelled else { return }

        let loadedEndIndex = startIndex + page.messageIDs.count
        let window = MessageWindow(
            startIndex: startIndex,
            endIndex: loadedEndIndex,
            messageIDs: page.messageIDs,
            isLoading: false
        )

        totalMessageCount = page.totalCount
        setMessageWindow(window)
        visibleMessages = messages
        placeholderIndices.removeAll()
        isLoadingMore = false
    }

    private func initialMessageRange(
        preferPendingConversationMessages: Bool = false
    ) async -> Range<Int> {
        switch initialWindowPosition {
        case .beginning:
            return 0..<configuration.visibleItemCount
        case .end:
            let totalCount = await loadTotalMessageCount(
                preferPendingConversationMessages: preferPendingConversationMessages
            )
            let startIndex = max(0, totalCount - configuration.visibleItemCount)
            return startIndex..<totalCount
        }
    }

    private func loadTotalMessageCount(
        preferPendingConversationMessages: Bool = false
    ) async -> Int {
        let metadataPage = await loadPage(
            0..<0,
            preferPendingConversationMessages: preferPendingConversationMessages
        )

        return metadataPage.totalCount
    }

    private func shouldReloadInitialEndWindowForPendingLocalMessages(
        preferredPendingMessages: Bool
    ) -> Bool {
        initialWindowPosition == .end &&
            !preferredPendingMessages &&
            hasPendingInsertedMessagesInConversation
    }

    private func loadPage(
        _ range: Range<Int>,
        preferPendingConversationMessages: Bool = false
    ) async -> VirtualScrollMessagePage {
        if preferPendingConversationMessages {
            return await Self.loadPendingMessagePage(
                conversationId: conversationId,
                range: range,
                in: viewContext
            )
        }

        return await pageLoader(conversationId, range, makeBackgroundContext())
    }

    private func preloadIfNeeded() {
        guard let window = messageWindow else { return }

        let distanceToEnd = window.endIndex - scrollPosition
        if distanceToEnd < configuration.preloadThreshold {
            preloadNext()
        }

        let distanceToStart = scrollPosition - window.startIndex
        if distanceToStart < configuration.preloadThreshold {
            preloadPrevious()
        }
    }

    private func preloadNext() {
        guard let window = messageWindow,
              window.endIndex < totalMessageCount else { return }

        let startIndex = window.endIndex
        let endIndex = min(totalMessageCount, startIndex + configuration.pageSize)
        let preferPendingConversationMessages = hasPendingInsertedMessagesInConversation

        taskManager.run("preloadNext") { [weak self] in
            guard let self = self else { return }

            let page = await self.loadPage(
                startIndex..<endIndex,
                preferPendingConversationMessages: preferPendingConversationMessages
            )

            guard !Task.isCancelled else { return }

            _ = await self.resolveRowsOnViewContext(for: page.messageIDs)

            guard !Task.isCancelled else { return }

            guard var currentWindow = self.messageWindow,
                  currentWindow.startIndex == window.startIndex,
                  currentWindow.endIndex == window.endIndex,
                  currentWindow.messageIDs == window.messageIDs else {
                return
            }

            currentWindow.messageIDs.append(contentsOf: page.messageIDs)
            currentWindow = MessageWindow(
                startIndex: currentWindow.startIndex,
                endIndex: startIndex + page.messageIDs.count,
                messageIDs: currentWindow.messageIDs,
                isLoading: false
            ).frontTrimmed(to: self.configuration.maxWindowSize)

            self.totalMessageCount = page.totalCount
            self.setMessageWindow(currentWindow)
            self.visibleMessages = self.resolveCachedRows(for: currentWindow.messageIDs)
        }
    }

    private func preloadPrevious() {
        guard let window = messageWindow,
              window.startIndex > 0 else { return }

        let endIndex = window.startIndex
        let startIndex = max(0, endIndex - configuration.pageSize)
        let preferPendingConversationMessages = hasPendingInsertedMessagesInConversation

        taskManager.run("preloadPrevious") { [weak self] in
            guard let self = self else { return }

            let page = await self.loadPage(
                startIndex..<endIndex,
                preferPendingConversationMessages: preferPendingConversationMessages
            )

            guard !Task.isCancelled else { return }

            _ = await self.resolveRowsOnViewContext(for: page.messageIDs)

            guard !Task.isCancelled else { return }

            guard var currentWindow = self.messageWindow,
                  currentWindow.startIndex == window.startIndex,
                  currentWindow.endIndex == window.endIndex,
                  currentWindow.messageIDs == window.messageIDs else {
                return
            }

            currentWindow.messageIDs = page.messageIDs + currentWindow.messageIDs

            // Back-trim against the window cap: the user is scrolling UP, so
            // the trimmed rows are far below the viewport and their removal
            // cannot shift visible content.
            currentWindow = MessageWindow(
                startIndex: startIndex,
                endIndex: currentWindow.endIndex,
                messageIDs: currentWindow.messageIDs,
                isLoading: false
            ).backTrimmed(to: self.configuration.maxWindowSize)

            self.totalMessageCount = page.totalCount
            self.setMessageWindow(currentWindow)
            self.visibleMessages = self.resolveCachedRows(for: currentWindow.messageIDs)
        }
    }

    /// Cancels all pending tasks when the scroll state is no longer needed
    func cleanup() {
        taskManager.cancelAll()
        viewContextChangesCancellable?.cancel()
        viewContextChangesCancellable = nil
    }

    private func startObservingViewContextChanges() {
        guard viewContextChangesCancellable == nil else { return }

        viewContextChangesCancellable = NotificationCenter.default.publisher(
            for: .NSManagedObjectContextObjectsDidChange,
            object: viewContext
        )
        .sink { [weak self] notification in
            self?.handleViewContextChange(notification)
        }
    }

    private func handleViewContextChange(_ notification: Notification) {
        guard let window = messageWindow else { return }

        // objectsDidChange fires for every merged sync save while a chat is
        // open. Bail out on type checks alone before any pass below faults
        // objects: only Message/Attachment changes and Person display-name
        // updates can affect this window.
        guard Self.isRelevantChatContextChange(notification.userInfo) else { return }

        let insertedMessageIDs = visibleInsertedMessageIDsForCurrentConversation(in: notification)
        if !insertedMessageIDs.isEmpty {
            insertedVisibleMessageIDs = insertedMessageIDs
        }

        let knownTotalCount = estimatedTotalCountAfterLocalMessageMutation(in: notification)
        if shouldRefreshLatestWindowForLocalMessageMutation(
            in: notification,
            currentWindow: window
        ) {
            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll local message mutation refresh requested conv=\(conversationId) knownTotal=\(knownTotalCount)",
                category: .ui
            )
            taskManager.run(localMutationRefreshTaskKey) { [weak self] in
                guard let self = self else { return }
                await self.refreshLatestWindowForLocalMutation(knownTotalCount: knownTotalCount)
            }
        } else if knownTotalCount > totalMessageCount {
            resolvedRowsByAbsoluteIndex.removeAll()
            totalMessageCount = knownTotalCount
            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll local message mutation count updated conv=\(conversationId) knownTotal=\(knownTotalCount)",
                category: .ui
            )
        }

        let boundaryMessageIDs = Set(resolvedRowsByAbsoluteIndex.values.map(\.objectID))
        let cachedMessageIDs = Set(window.messageIDs).union(boundaryMessageIDs)
        guard !cachedMessageIDs.isEmpty else { return }

        let affectedMessageIDs = refreshedCachedMessageIDs(
            in: notification,
            cachedMessageIDs: cachedMessageIDs
        )

        guard !affectedMessageIDs.isEmpty else { return }

        let didInvalidateBoundaryRow = !boundaryMessageIDs.isDisjoint(with: affectedMessageIDs)
        invalidateCachedRows(for: affectedMessageIDs)

        let refreshedRows = resolveCachedRows(for: window.messageIDs)
        guard didInvalidateBoundaryRow || refreshedRows != visibleMessages else { return }
        visibleMessages = refreshedRows
    }

    private func refreshedCachedMessageIDs(
        in notification: Notification,
        cachedMessageIDs: Set<NSManagedObjectID>
    ) -> Set<NSManagedObjectID> {
        var affectedMessageIDs = Set<NSManagedObjectID>()

        for object in contextObjects(
            forKeys: [NSUpdatedObjectsKey, NSRefreshedObjectsKey, NSDeletedObjectsKey],
            in: notification
        ) {
            guard let message = object as? Message,
                  cachedMessageIDs.contains(message.objectID) else {
                continue
            }

            affectedMessageIDs.insert(message.objectID)
        }

        for object in contextObjects(
            forKeys: [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSRefreshedObjectsKey, NSDeletedObjectsKey],
            in: notification
        ) {
            guard let attachment = object as? Attachment,
                  let messageID = attachment.message?.objectID,
                  cachedMessageIDs.contains(messageID) else {
                continue
            }

            affectedMessageIDs.insert(messageID)
        }

        let changedPersonEmails = Set(contextObjects(
            forKeys: [NSUpdatedObjectsKey, NSRefreshedObjectsKey],
            in: notification
        ).compactMap { object -> String? in
            guard let person = object as? Person else { return nil }
            let email = EmailNormalizer.normalize(person.email)
            return email.isEmpty ? nil : email
        })

        if !changedPersonEmails.isEmpty {
            for messageID in cachedMessageIDs {
                guard let row = resolveCachedRow(for: messageID),
                      row.matchesSenderEmail(in: changedPersonEmails) else {
                    continue
                }

                affectedMessageIDs.insert(messageID)
            }
        }

        return affectedMessageIDs
    }

    private func shouldRefreshLatestWindowForLocalMessageMutation(
        in notification: Notification,
        currentWindow: MessageWindow
    ) -> Bool {
        guard currentWindow.endIndex >= totalMessageCount else {
            return false
        }

        return hasVisibleInsertedMessageForCurrentConversation(in: notification)
    }

    /// Type-check-only relevance scan for objectsDidChange payloads. Nothing
    /// here faults an object; the expensive relationship checks below only
    /// run for notifications that pass this.
    nonisolated static func isRelevantChatContextChange(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let userInfo else { return false }

        let keys = [
            NSInsertedObjectsKey,
            NSUpdatedObjectsKey,
            NSRefreshedObjectsKey,
            NSDeletedObjectsKey
        ]
        let personKeys: Set<String> = [NSUpdatedObjectsKey, NSRefreshedObjectsKey]

        for key in keys {
            guard let objects = userInfo[key] as? Set<NSManagedObject> else { continue }
            let includesPersons = personKeys.contains(key)
            for object in objects {
                if object is Message || object is Attachment {
                    return true
                }
                if includesPersons, object is Person {
                    return true
                }
            }
        }
        return false
    }

    /// Resolved once (objectID-only fetch) so conversation membership checks
    /// compare objectIDs instead of faulting each inserted message's
    /// Conversation row for its UUID. Temporary IDs (optimistic unsaved
    /// conversations) are not cached — they change identity on save.
    private func currentConversationObjectID() -> NSManagedObjectID? {
        if let cachedConversationObjectID {
            return cachedConversationObjectID
        }
        guard let conversationUUID = UUID(uuidString: conversationId) else { return nil }

        let request = NSFetchRequest<NSManagedObjectID>(entityName: "Conversation")
        request.predicate = NSPredicate(format: "id == %@", conversationUUID as CVarArg)
        request.resultType = .managedObjectIDResultType
        request.fetchLimit = 1

        let objectID = (try? viewContext.fetch(request))?.first
        if let objectID, !objectID.isTemporaryID {
            cachedConversationObjectID = objectID
        }
        return objectID
    }

    /// Membership check that faults at most the message row: the destination
    /// objectID of the to-one relationship is available without firing the
    /// Conversation's own fault (the previous UUID comparison loaded the
    /// Conversation row for every inserted message in every merge).
    private func belongsToCurrentConversation(_ message: Message) -> Bool {
        guard let conversationObjectID = currentConversationObjectID() else { return false }
        return message.conversation?.objectID == conversationObjectID
    }

    private func hasVisibleInsertedMessageForCurrentConversation(in notification: Notification) -> Bool {
        contextObjects(forKeys: [NSInsertedObjectsKey], in: notification)
            .contains { object in
                guard let message = object as? Message,
                      belongsToCurrentConversation(message) else {
                    return false
                }

                return isVisibleInChat(message)
            }
    }

    private func estimatedTotalCountAfterLocalMessageMutation(in notification: Notification) -> Int {
        let insertedCount = visibleInsertedMessageCountForCurrentConversation(in: notification)

        return max(0, totalMessageCount + insertedCount)
    }

    private func visibleInsertedMessageCountForCurrentConversation(in notification: Notification) -> Int {
        visibleInsertedMessageIDsForCurrentConversation(in: notification).count
    }

    private func visibleInsertedMessageIDsForCurrentConversation(
        in notification: Notification
    ) -> [NSManagedObjectID] {
        contextObjects(forKeys: [NSInsertedObjectsKey], in: notification)
            .compactMap { object -> NSManagedObjectID? in
                guard let message = object as? Message,
                      !message.objectID.isTemporaryID,
                      belongsToCurrentConversation(message),
                      isVisibleInChat(message) else {
                    return nil
                }

                return message.objectID
            }
            .sorted {
                $0.uriRepresentation().absoluteString < $1.uriRepresentation().absoluteString
            }
    }

    private func isVisibleInChat(_ message: Message) -> Bool {
        let excludedLabelIDs = Set(MessagePredicates.chatExcludedLabelIDs)
        let labelIDs = message.labels?.map(\.id) ?? []
        return labelIDs.allSatisfy { !excludedLabelIDs.contains($0) }
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

    private func setMessageWindow(_ window: MessageWindow) {
        messageWindow = window
        resolvedRowsByAbsoluteIndex.removeAll()

        let allowedIDs = Set(window.messageIDs)
        resolvedRowsByID = resolvedRowsByID.filter { allowedIDs.contains($0.key) }
    }

    private func invalidateCachedRows(for objectIDs: Set<NSManagedObjectID>) {
        guard !objectIDs.isEmpty else { return }

        for objectID in objectIDs {
            resolvedRowsByID.removeValue(forKey: objectID)
        }

        resolvedRowsByAbsoluteIndex = resolvedRowsByAbsoluteIndex.filter { _, row in
            !objectIDs.contains(row.objectID)
        }
    }

    // The original bug was caused by fetching `Message` instances in a background
    // context and then storing those managed objects on `@MainActor` state. We now
    // re-resolve background-fetched object IDs on the viewContext before mapping
    // them into lightweight row snapshots for SwiftUI.
    private func resolveRowsOnViewContext(
        for messageIDs: [NSManagedObjectID]
    ) async -> [ChatMessageRowModel] {
        guard !messageIDs.isEmpty else { return [] }

        let request = NSFetchRequest<Message>(entityName: "Message")
        request.predicate = NSPredicate(format: "SELF IN %@", messageIDs)
        request.fetchBatchSize = messageIDs.count
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person", "attachments"]

        let fetchedMessages = (try? viewContext.fetch(request)) ?? []
        let resolvedRows: [NSManagedObjectID: ChatMessageRowModel] = Dictionary(
            uniqueKeysWithValues: fetchedMessages.compactMap { message in
                guard !message.isDeleted else { return nil }
                return (message.objectID, ChatMessageRowModelMapper.map(message))
            }
        )

        for objectID in messageIDs {
            if let row = resolvedRows[objectID] {
                resolvedRowsByID[objectID] = row
            } else {
                resolvedRowsByID.removeValue(forKey: objectID)
            }
        }

        return messageIDs.compactMap { resolvedRows[$0] }
    }

    func row(atAbsoluteIndex index: Int) -> ChatMessageRowModel? {
        guard let window = messageWindow,
              window.contains(index: index) else {
            return nil
        }

        let relativeIndex = index - window.startIndex
        guard relativeIndex >= 0, relativeIndex < window.messageIDs.count else {
            return nil
        }

        return resolveCachedRow(for: window.messageIDs[relativeIndex])
    }

    func rowForGrouping(atAbsoluteIndex index: Int) -> ChatMessageRowModel? {
        if let row = row(atAbsoluteIndex: index) {
            return row
        }

        guard index >= 0, index < totalMessageCount else { return nil }
        if let cached = resolvedRowsByAbsoluteIndex[index] {
            return cached
        }
        guard let conversationUUID = UUID(uuidString: conversationId) else { return nil }

        let request = NSFetchRequest<Message>(entityName: "Message")
        request.predicate = MessagePredicates.visibleInChat(conversationId: conversationUUID)
        request.sortDescriptors = [NSSortDescriptor(key: "internalDate", ascending: true)]
        request.fetchOffset = index
        request.fetchLimit = 1
        request.fetchBatchSize = 1
        request.includesPendingChanges = true
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person", "attachments"]

        guard let message = try? viewContext.fetch(request).first,
              !message.isDeleted else {
            return nil
        }

        let row = ChatMessageRowModelMapper.map(message)
        resolvedRowsByID[message.objectID] = row
        resolvedRowsByAbsoluteIndex[index] = row
        return row
    }

    private func resolveCachedRows(for messageIDs: [NSManagedObjectID]) -> [ChatMessageRowModel] {
        messageIDs.compactMap(resolveCachedRow)
    }

    private func resolveCachedRow(for objectID: NSManagedObjectID) -> ChatMessageRowModel? {
        if let cached = resolvedRowsByID[objectID] {
            return cached
        }

        if let registered = viewContext.registeredObject(for: objectID) as? Message,
           !registered.isDeleted {
            let row = ChatMessageRowModelMapper.map(registered)
            resolvedRowsByID[objectID] = row
            return row
        }

        do {
            guard let resolved = try viewContext.existingObject(with: objectID) as? Message,
                  !resolved.isDeleted else {
                resolvedRowsByID.removeValue(forKey: objectID)
                return nil
            }

            let row = ChatMessageRowModelMapper.map(resolved)
            resolvedRowsByID[objectID] = row
            return row
        } catch {
            resolvedRowsByID.removeValue(forKey: objectID)
            return nil
        }
    }

    nonisolated static func loadMessagePage(
        conversationId: String,
        range: Range<Int>,
        in context: NSManagedObjectContext
    ) async -> VirtualScrollMessagePage {
        guard let conversationUUID = UUID(uuidString: conversationId) else {
            return VirtualScrollMessagePage(messageIDs: [], totalCount: 0)
        }

        let predicate = MessagePredicates.visibleInChat(conversationId: conversationUUID)
        nonisolated(unsafe) let safePredicate = predicate

        return await context.perform {
            let messageIDs: [NSManagedObjectID]
            if range.isEmpty {
                messageIDs = []
            } else {
                let request = NSFetchRequest<NSManagedObjectID>(entityName: "Message")
                request.predicate = safePredicate
                request.sortDescriptors = [NSSortDescriptor(key: "internalDate", ascending: true)]
                request.fetchOffset = range.lowerBound
                request.fetchLimit = range.count
                request.fetchBatchSize = 20
                request.includesPendingChanges = false
                request.resultType = .managedObjectIDResultType
                messageIDs = (try? context.fetch(request)) ?? []
            }

            // Keep count() on the background context so window sizing stays cheap and
            // the main actor only resolves the IDs it actually needs to render.
            let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            countRequest.predicate = safePredicate
            countRequest.includesPendingChanges = false
            let totalCount = (try? context.count(for: countRequest)) ?? 0

            return VirtualScrollMessagePage(messageIDs: messageIDs, totalCount: totalCount)
        }
    }

    nonisolated private static func loadPendingMessagePage(
        conversationId: String,
        range: Range<Int>,
        in context: NSManagedObjectContext
    ) async -> VirtualScrollMessagePage {
        guard let conversationUUID = UUID(uuidString: conversationId) else {
            return VirtualScrollMessagePage(messageIDs: [], totalCount: 0)
        }

        let predicate = MessagePredicates.visibleInChat(conversationId: conversationUUID)
        nonisolated(unsafe) let safePredicate = predicate

        return await context.perform {
            let messages: [Message]
            if range.isEmpty {
                messages = []
            } else {
                let request = NSFetchRequest<Message>(entityName: "Message")
                request.predicate = safePredicate
                request.sortDescriptors = [NSSortDescriptor(key: "internalDate", ascending: true)]
                request.fetchOffset = range.lowerBound
                request.fetchLimit = range.count
                request.fetchBatchSize = 20
                request.includesPendingChanges = true
                messages = (try? context.fetch(request)) ?? []
            }

            let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            countRequest.predicate = safePredicate
            countRequest.includesPendingChanges = true
            let totalCount = (try? context.count(for: countRequest)) ?? 0

            return VirtualScrollMessagePage(
                messageIDs: messages.map(\.objectID),
                totalCount: totalCount
            )
        }
    }
}

private extension VirtualScrollState.InitialWindowPosition {
    var diagnosticName: String {
        switch self {
        case .beginning:
            return "beginning"
        case .end:
            return "end"
        }
    }
}

private extension ChatMessageRowModel {
    func matchesSenderEmail(in emails: Set<String>) -> Bool {
        [
            senderInfoEmail,
            effectiveSenderEmail,
            senderEmail
        ]
        .compactMap { $0 }
        .map(EmailNormalizer.normalize)
        .contains { emails.contains($0) }
    }
}
