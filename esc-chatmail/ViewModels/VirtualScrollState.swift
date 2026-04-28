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
    @Published var placeholderIndices: Set<Int> = []

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
    private var viewContextChangesCancellable: AnyCancellable?

    // Task tracking to prevent orphaned tasks during rapid scrolling
    private let taskManager = ViewModelTaskManager()

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
        isLoadingMore = true

        taskManager.run("loadInitial") { [weak self] in
            guard let self = self else { return }

            let preferPendingConversationMessages =
                self.initialWindowPosition == .end && self.hasPendingInsertedMessagesInConversation
            let initialRange = await self.initialMessageRange(
                preferPendingConversationMessages: preferPendingConversationMessages
            )
            let page = await self.loadPage(
                initialRange,
                preferPendingConversationMessages: preferPendingConversationMessages
            )

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
        }
    }

    func loadLatestWindowIfNeeded() async {
        guard !isShowingLatestWindow || visibleMessages.isEmpty || hasPendingInsertedMessagesInConversation else {
            return
        }

        await loadLatestWindow()
    }

    func loadLatestWindow() async {
        let preferPendingConversationMessages = hasPendingInsertedMessagesInConversation
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
            )

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
            currentWindow = MessageWindow(
                startIndex: startIndex,
                endIndex: currentWindow.endIndex,
                messageIDs: currentWindow.messageIDs,
                isLoading: false
            )

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
        guard let window = messageWindow,
              !window.messageIDs.isEmpty else { return }

        let visibleMessageIDs = Set(window.messageIDs)
        let affectedMessageIDs = refreshedVisibleMessageIDs(
            in: notification,
            visibleMessageIDs: visibleMessageIDs
        )

        guard !affectedMessageIDs.isEmpty else { return }

        for objectID in affectedMessageIDs {
            resolvedRowsByID.removeValue(forKey: objectID)
        }

        let refreshedRows = resolveCachedRows(for: window.messageIDs)
        guard refreshedRows != visibleMessages else { return }
        visibleMessages = refreshedRows
    }

    private func refreshedVisibleMessageIDs(
        in notification: Notification,
        visibleMessageIDs: Set<NSManagedObjectID>
    ) -> Set<NSManagedObjectID> {
        var affectedMessageIDs = Set<NSManagedObjectID>()

        for object in contextObjects(
            forKeys: [NSUpdatedObjectsKey, NSRefreshedObjectsKey],
            in: notification
        ) {
            guard let message = object as? Message,
                  visibleMessageIDs.contains(message.objectID) else {
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
                  visibleMessageIDs.contains(messageID) else {
                continue
            }

            affectedMessageIDs.insert(messageID)
        }

        return affectedMessageIDs
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

        let allowedIDs = Set(window.messageIDs)
        resolvedRowsByID = resolvedRowsByID.filter { allowedIDs.contains($0.key) }
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
